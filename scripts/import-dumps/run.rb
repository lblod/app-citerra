#!/usr/bin/env ruby
require 'bundler/inline'
require 'yaml'
require 'uri'
require 'net/http'
require 'json'
require 'tty-prompt'
require 'securerandom'
require 'date'

$stdout.sync = true
print "installing ruby dependencies..."
gemfile do
  source 'https://rubygems.org'
  gem 'ruby-odbc'
  gem 'typhoeus'
  gem 'tty-progressbar'
  gem 'logger'
end
puts "done"

require 'odbc'
require 'typhoeus'

ENV['LOG_SPARQL_ALL']='false'
ENV['MU_SPARQL_ENDPOINT']='http://database:8890/sparql'
ENV['JENA_HOME']='/opt/jena'

# using jena riot because we need streaming validation because of large files
puts "installing jena riot for turtle validation"
`apt-get update && apt-get install -y openjdk-17-jdk wget unzip`
`wget -qO- https://downloads.apache.org/jena/binaries/apache-jena-5.3.0.tar.gz | tar xz -C /opt && \
    mv /opt/apache-jena-5.3.0 $JENA_HOME && \
    ln -s $JENA_HOME/bin/riot /usr/local/bin/riot`


require 'odbc'
require 'tty-prompt'

DSN_NAME = "VirtuosoDSN"
ODBC_INI_PATH = "/etc/odbc.ini"
DRIVER_PATH = File.expand_path('./virtodbcu_r.so')
JOBS_GRAPH="http://mu.semte.ch/graphs/system/jobs"

class DateTime
  def sparql_escape
    '"' + self.xmlschema + '"^^xsd:dateTime'
  end
end

def dsn_exists?
  return false unless File.exist?(ODBC_INI_PATH)

  File.readlines(ODBC_INI_PATH).any? { |line| line.strip == "[#{DSN_NAME}]" }
end

# somewhat silly, but the only way I got a workign dsn set up
def write_dsn_config
  dsn_config = <<~DSN
    [#{DSN_NAME}]
    Driver=#{DRIVER_PATH}
    Address=triplestore:1111
  DSN

  unless dsn_exists?
    File.open(ODBC_INI_PATH, "a") do |file|
      file.puts "\n" + dsn_config
    end
  end
end

def get_db_connection
  write_dsn_config
  begin
    dbh = ODBC.connect(DSN_NAME, 'dba', 'dba')
    dbh.autocommit = true
    puts "Connected successfully to DSN: #{DSN_NAME}"
    return dbh
  rescue ODBC::Error => e
    puts "ODBC Error: #{e.message}"
    return nil
  end
end

def get_latest_dump_file(sync_base_url, subject)
  sync_base_url = sync_base_url.end_with?("/") ? sync_base_url : "#{sync_base_url}/"
  sync_dataset_endpoint = "#{sync_base_url}datasets"
  begin
    url_to_call = "#{sync_dataset_endpoint}?filter[subject]=#{subject}&filter[:has-no:next-version]=yes"
    puts "Retrieving latest dataset from #{url_to_call}"

    response_dataset = Typhoeus.get(url_to_call, headers: { 'Accept' => 'application/vnd.api+json' })
    dataset = JSON.parse(response_dataset.body)

    if dataset['data'].any?
      distribution_metadata = dataset['data'][0]['attributes']
      distribution_related_link = dataset['data'][0]['relationships']['distributions']['links']['related']
      distribution_uri = "#{sync_base_url}#{distribution_related_link}"

      puts "Retrieving distribution from #{distribution_uri}"
      result_distribution = Typhoeus.get("#{distribution_uri}?include=subject", headers: { 'Accept' => 'application/vnd.api+json' })
      distribution = JSON.parse(result_distribution.body)
      return [distribution['data'][0].dig('relationships','subject','data'), distribution_metadata]
    else
      raise 'No dataset was found at the producing endpoint.'
    end
  rescue => e
    puts "Unable to retrieve dataset from #{sync_dataset_endpoint}"
    raise e
  end
end

def fetch_and_store_file(prompt, sync_base_url, sync_dataset_subject)
  distribution, distribution_metadata = get_latest_dump_file(sync_base_url, sync_dataset_subject)
  prompt.say "Dateset has release-date #{distribution_metadata["release-date"]}"
  distribution_url = "#{sync_base_url}files/#{distribution["id"]}/download"
  progressbar = nil
  tmp_file_path = "/project/tmp-#{distribution["id"]}.ttl"
  prompt.say "Downloading file from #{distribution_url} to #{tmp_file_path}"
  progressbar = TTY::ProgressBar.new("Downloading: :byte_rate/s :current_byte :elapsed")
  file = File.open(tmp_file_path, 'wb')
  request = Typhoeus::Request.new(distribution_url, followlocation: true, accept_encoding: 'deflate,gzip')
  request.on_headers do |response|
    if response.code != 200
      raise "Failed to download file, response code #{response.code}"
    end
    puts response.headers["Content-Encoding"]
  end
  request.on_body do |chunk|
    file.write(chunk)
    progressbar.advance(chunk.bytesize) if progressbar
  end
  request.on_complete do
    file.close
    progressbar.finish
  end
  request.run
  return [tmp_file_path, distribution_metadata["release-date"]]
end

prompt = TTY::Prompt.new
prompt.say ""
choices = [
  {name: "https://lokaalbeslist-harvester-0.s.redhost.be/", value: 1 },
  {name: "https://lokaalbeslist-harvester-1.s.redhost.be/", value: 2 },
  {name: "https://lokaalbeslist-harvester-2.s.redhost.be/", value: 3 },
  {name: "https://lokaalbeslist-harvester-3.s.redhost.be/", value: 4 },
  {name: "https://dev.harvesting-self-service.lblod.info/", value: "dev" },
  {name: "custom", value: "custom"}
]

harvester = prompt.select("From which harvester are you importing?", choices)
if harvester == "custom"
  sync_base_url = prompt.ask('Enter the SYNC_BASE_URL:', default: "https://lokaalbeslist-harvester-0.s.redhost.be/")
  ingest_graph = prompt.ask("Enter the INGEST_GRAPH", default: "http://mu.semte.ch/graphs/public")
  job_creator_uri = prompt.ask("Enter the JOB_CREATOR_URI", default: "http://data.lblod.info/services/id/besluiten-consumer")
  default_subject = "http://data.lblod.info/datasets/delta-producer/dumps/lblod-harvester/BesluitenCacheGraphDump"
  sync_dataset_subject = prompt.ask("Enter the dataset URI:", default: default_subject)
  job_operation = prompt.ask("Enter the job operation for the initalsync metadata", default: "http://redpencil.data.gift/id/jobs/concept/JobOperation/deltas/consumer/initialSync/besluiten")
elsif harvester == "dev"
  sync_base_url = "https://dev.harvesting-self-service.lblod.info/"
  ingest_graph = "http://mu.semte.ch/graphs/public"
  job_creator_uri = "http://data.lblod.info/services/id/besluiten-consumer"
  sync_dataset_subject = "http://data.lblod.info/datasets/delta-producer/dumps/lblod-harvester/BesluitenCacheGraphDump"
  job_operation =  "http://redpencil.data.gift/id/jobs/concept/JobOperation/deltas/consumer/initialSync/besluiten"
else
  # a prod harvester
  sync_base_url = "https://lokaalbeslist-harvester-#{harvester-1}.s.redhost.be/"
  ingest_graph = "http://mu.semte.ch/graphs/harvester-#{harvester-1}"
  job_creator_uri = "http://data.lblod.info/services/id/besluiten-consumer"
  sync_dataset_subject = "http://data.lblod.info/datasets/delta-producer/dumps/lblod-harvester/BesluitenCacheGraphDump"
  job_operation =  "http://redpencil.data.gift/id/jobs/concept/JobOperation/deltas/consumer/initialSync/besluiten"
  if harvester > 1
    job_creator_uri = "http://data.lblod.info/services/id/besluiten-consumer-#{harvester-1}"
    job_operation = "http://redpencil.data.gift/id/jobs/concept/JobOperation/deltas/consumer/initialSync/besluiten-#{harvester-1}"
  end
end

fetch_from = prompt.select("Fetch file from endpoint or filesystem?", ["endpoint", "filesystem"])
start=DateTime.now
if fetch_from == "endpoint"
  tmp_file_path, distribution_id, release_date = fetch_and_store_file(prompt, sync_base_url,sync_dataset_subject)
else
  tmp_file_path = prompt.ask("Where is the file located (project folder mounted under /project)", default: "/project/dump.ttl")
  release_date = prompt.ask("What was the generation time for this file (used by delta-consumer as since)", default: DateTime.now.xmlschema)
  distribution_id = prompt.ask("Enter the distribution id", default: SecureRandom.uuid)
end
prompt.say "Validating file #{tmp_file_path}"
system("/usr/local/bin/riot --validate #{tmp_file_path}")
unless $?.success?
  raise "Downloaded turtle file is not a valid turtle file"
end
filename="dataset-#{SecureRandom.uuid}.ttl"
File.rename(tmp_file_path,"/project/data/db/toLoad/#{filename}")
prompt.say("Moved validated ttl to data/db/toLoad/#{filename}")
load_file = prompt.yes?("Load file via virtuoso odbc")
if load_file
  begin
    connection = get_db_connection
    progressbar = TTY::ProgressBar.new("Loading file [:bar] :elapsed")
    connection.do("ld_dir('toLoad', '#{filename}', '#{ingest_graph}' )")
    connection.do("rdf_loader_run()")
    connection.do("exec('checkpoint')")
    progressbar.finish
    prompt.say("File successfully loaded into #{ingest_graph}.")
  rescue => e
    puts e.backtrace
    exit(1)
  end
end
end_time = DateTime.now
prompt.say("Adding initial starting point for delta sync")
begin
  container_id = SecureRandom.uuid
  container_uri = "http://data.lblod.info/id/dataContainers/#{container_id}";
  job_id = SecureRandom.uuid
  job_uri = "http://redpencil.data.gift/id/job/#{job_id}"
  task_id = SecureRandom.uuid
  task_uri = "http://redpencil.data.gift/id/task/#{task_id}"
  task_1_id = SecureRandom.uuid
  task_1_uri = "http://redpencil.data.gift/id/task/#{task_1_id}"
  metadata_query = <<~QUERY
SPARQL
PREFIX mu: <http://mu.semte.ch/vocabularies/core/>
PREFIX task: <http://redpencil.data.gift/vocabularies/tasks/>
PREFIX dct: <http://purl.org/dc/terms/>
PREFIX prov: <http://www.w3.org/ns/prov#>
PREFIX ext: <http://mu.semte.ch/vocabularies/ext/>
PREFIX oslc: <http://open-services.net/ns/core#>
PREFIX cogs: <http://vocab.deri.ie/cogs#>
PREFIX adms: <http://www.w3.org/ns/adms#>
PREFIX nfo: <http://www.semanticdesktop.org/ontologies/2007/03/22/nfo#>
INSERT DATA {
     GRAPH <#{JOBS_GRAPH}> {
       <#{job_uri}> a cogs:Job;
                    mu:uuid "#{job_id}";
                    dct:creator <#{job_creator_uri}>;
                dct:created #{start.sparql_escape};
                dct:modified #{end_time.sparql_escape};
                adms:status <http://redpencil.data.gift/id/concept/JobStatus/success>;
          task:operation <#{job_operation}>.
       <#{task_uri}> a task:Task;
                mu:uuid "#{task_id}";
                dct:isPartOf <#{job_uri}>;
                dct:created #{start.sparql_escape};
                dct:modified #{end_time.sparql_escape};
                adms:status <http://redpencil.data.gift/id/concept/JobStatus/success>;
                task:index 0;
                task:operation <http://redpencil.data.gift/id/jobs/concept/TaskOperation/deltas/consumer/initialSyncing>.
       <#{task_1_uri}> a task:Task;
                mu:uuid "#{task_1_id}";
                dct:isPartOf <#{job_uri}>;
                dct:created #{start.sparql_escape};
                dct:modified #{end_time.sparql_escape};
                adms:status <http://redpencil.data.gift/id/concept/JobStatus/success>;
                task:index 1;
                task:operation <http://redpencil.data.gift/id/jobs/concept/TaskOperation/deltas/consumer/deltaSyncing>.
      <#{container_uri}> a nfo:DataContainer;
                          dct:subject <http://redpencil.data.gift/id/concept/DeltaSync/DeltafileInfo>;
                          mu:uuid "#{container_id}";
                          ext:hasDeltafileTimestamp "#{release_date}"^^xsd:dateTime;
                          ext:hasDeltafileId "#{distribution_id}";
                          ext:hasDeltafileName "#{filename}".
      <#{task_1_uri}> task:resultsContainer <#{container_uri}>.
      <#{task_1_uri}> task:inputContainer  <#{container_uri}>.
     }
    }
QUERY
  connection = get_db_connection
  prompt.say("Executing query: \n #{metadata_query}")
  connection.do(metadata_query)
end
