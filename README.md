# Citerra (back-end)

[The back-end for citerra](https://citerra.lokaalbeslist.lblod.info/), a project that uses linked data to empower everyone in Flanders to consult the decisions made by their local authorities.

This project has different important moving parts:
- The harvester (which is available in [the app-lblod-harvester repository](https://github.com/lblod/app-lblod-harvester)). This processes government-provided data into consumable [data endpoints, which you can view here](#what-endpoints-can-be-used)
- The back-end (this repository). This is a docker-compose configuration that combines the front-end together with other services.
- The front-end (which is available in [the frontend-citerra repo](https://github.com/lblod/frontend-citerra)). This is an Ember frontend


You can check out more info on besluitendatabanken [here](https://lokaalbestuur.vlaanderen.be/besluitendatabank), and the [back-end](https://github.com/lblod/frontend-citerra) here. The front-end repo only contains front-end specific information, back-and and general project info will be added here.



## Tutorials
You can run this app in a few different ways
- Only run the front-end and use the existing back-end. [Instructions for this can be found in the frontend repo](https://github.com/lblod/frontend-citerra)
- Run the back-end with your own consumers & front-end included. [Instructions for this are found below](#basic-setup)

**Pre-requisites**: Docker & Docker-Compose installed. Some parts of the tutorials may use drc as an alias for docker-compose

### Basic setup
First, clone the repository
```bash
git clone https://github.com/lblod/app-citerra.git
cd app-citerra.git
```

#### Selecting endpoints
[You can view the existing endpoints here](#what-endpoints-can-be-used)

```yml
services:
  mandatendatabank-consumer:
   environment:
      DCR_SYNC_BASE_URL: "https://example.com/"
  op-public-consumer:
   environment:
      DCR_SYNC_BASE_URL: "https://example.com/"
  besluiten-consumer:
    environment:
      DCR_SYNC_BASE_URL: "https://example.com/"
```

#### (Optional) Set uuid-generation cronjob
```yml
services:
  uuid-generation:
    environment:
      RUN_CRON_JOBS: "true"
      CRON_FREQUENCY: "0 * * * *"
```

#### (Optional) Enable Plausible Analytics
```yml
services:
  frontend:
    environment:
      EMBER_PLAUSIBLE_APIHOST: "https://example.com"
      EMBER_PLAUSIBLE_DOMAIN: "example.com"
```

Then start the server using `docker-compose up --detach`


### Sync data external data consumers
The procedure below describes how to set up the sync for besluiten-consumer.
The procedures should be the similar for `op-public-consumer` and `mandatendatabank-consumer`. If there are variations in the steps for these consumers, it will be noted.

The synchronization of external data sources is a structured process divided into three key stages. The first stage, known as 'initial sync', requires manual interventions primarily due to performance considerations. Following this, there's a post-processing stage, where depending on the delta-consumer stream, it may be necessary to initiate certain background processes to ensure system consistency. The final stage involves transitioning the system to the 'normal operation' mode, wherein all functions are designed to be executed automatically.

##### 1. Initial sync
##### From scratch
It's recommend you use the mu-cli scripts provided in this repository to set up the initial sync, this will load data straight into virtuoso and will be the quickest way to get started.

First start the triplestore and migrations service
```sh
drc up -d triplestore migrations
```

Once migrations have finished. Run the import-dump script to start an interactive wizard to load the necessary data.
```sh
mu script project-scripts import-dump
```

*Note:* in some cases (for dumps > 6GB), fetching the dump might fail. in that case note down the logged metadata (release-date, uuid used in the filename), copy the dump through scp and run the script again but load from filesystem instead of endpoint.

Once all imports have finished (you need at least a besluiten, mandatendb and organisation portal dump). Start database, elasticsearch and search to create the search indexes.


After that set up regular sync  with the following steps:

- ensure docker-compose.override.yml has AT LEAST the following information

```yml
services:
#(...) there might be other services

  besluiten-consumer:
    environment:
      DCR_SYNC_BASE_URL: "https://harvesting-self-service.lblod.info/" # you choose endpoint here
      DCR_DISABLE_DELTA_INGEST: "false"
      DCR_DISABLE_INITIAL_SYNC: "false" # the import script creates the necessary metadata, from a service point of view the ingest has happened
# (...) there might be other information
```
Ensure the flag `BYPASS_MU_AUTH_FOR_EXPENSIVE_QUERIES` is set to `false` for **EVERY CONSUMER**

- start the stack. `drc up -d`.

  Data should be ingesting.
  Check the logs `drc logs -f --tail=200 besluiten-consumer`

##### In case of a re-sync
In some cases, you may need to reset the data due to unforeseen issues. The simplest method is to entirely flush the triplestore and start afresh. However, this can be time-consuming, and if the app possesses an internal state that can't be recreated from external sources, a more granular approach would be necessary. We will outline this approach here. Currently, it involves a series of manual steps, but we hope to enhance the level of automation in the future.

###### besluiten-consumer

- step 1: ensure the app is running and all migrations ran.
- step 2: ensure the besluiten-consumer stopped syncing, `docker-compose.override.yml` should AT LEAST contain the following information
```yml
services:
#(...) there might be other services

  besluiten-consumer:
    environment:
      DCR_DISABLE_DELTA_INGEST: "true"
      DCR_DISABLE_INITIAL_SYNC: "true"
     # (...) there might be other information e.g. about the endpoint

# (...) there might be other information
```
- step 3: `docker-compose up -d besluiten-consumer` to re-create the container.
- step 4: We need to flush the ingested data. Sample migrations have been provided.
```
cp ./config/sample-migrations/flush-besluiten-consumer.sparql-template ./config/migrations/local/[TIMESTAMP]-flush-besluiten-consumer.sparql
docker-compose restart migrations
```
- step 5: Once migrations a success, further `besluiten-consumer` data needs to be flushed too.
```
docker-compose exec besluiten-consumer curl -X POST http://localhost/flush
docker-compose logs -f --tail=200 besluiten-consumer 2>&1 | grep -i "flush"
```
  - This should end with `Flush successful`.
- step 6: Proceed to consuming data from scratch again, make sure the consumers are off and run the import script to import a new dump.

###### op-public-consumer & mandatendatabank-consumer
As of the time of writing, there is some overlap between the two data producers due to practical reasons. This issue will be resolved eventually. For the time being, if re-synchronization is required, it's advisable to re-sync both consumers.
The procedure is identical to the one for besluiten-consumer, but with a bit of an extra synchronsation hassle.
For both consumers you will need to first run steps 1 up to and including step 5. Once these steps completed for both consumers, you can proceed and start ingesting the data again.

#### 2. post-processing
For all delta-streams, you'll have to run `docker-compose restart resources cache`.
##### search
In order to trigger a full mu-search reindex, you can execute `sudo bash ./scripts/reset-elastic.sh` (the stack must be up).
It takes a while to reindex, please consider using a small dataset to speed it up.

#### What endpoints can be used?
##### besluiten-consumer

- Production data: https://harvesting-self-service.prod.lblod.info/
- QA data: https://harvesting-self-service.lblod.info/
- DEV data: https://dev.harvesting-self-service.lblod.info/

#### besluiten harvester SPARQL endpoints
*Note*: See docker-compose.prod.yml for an example setup of the consumers.

- Production data:
  - https://lokaalbeslist-harvester-0.s.redhost.be/sparql
  - https://lokaalbeslist-harvester-1.s.redhost.be/sparql
  - https://lokaalbeslist-harvester-2.s.redhost.be/sparql
  - https://lokaalbeslist-harvester-3.s.redhost.be/sparql

##### mandatendatabank-consumer

- Production data: https://loket.lokaalbestuur.vlaanderen.be/
- QA data: https://loket.lblod.info/
- DEV data: https://dev.loket.lblod.info/

##### op-public-consumer

- Production data: https://organisaties.abb.vlaanderen.be/
- QA data: https://organisaties.abb.lblod.info/
- DEV data: https://dev.organisaties.abb.lblod.info/

### Setup local development environment
To setup a local development environment, you can follow the steps below.

1. Clone the repository
2. Create .env file in the root of the project: `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml > .env`
3. Run `docker-compose up -d`
4. Wait for all initialSync consumers to finish. You can check progression with this sparql query:
```sparql
PREFIX adms: <http://www.w3.org/ns/adms#>
PREFIX task: <http://redpencil.data.gift/vocabularies/tasks/>
PREFIX dct: <http://purl.org/dc/terms/>
PREFIX cogs: <http://vocab.deri.ie/cogs#>

SELECT ?s ?operation ?status ?created ?modified ?creator WHERE {
  ?s a cogs:Job ;
    adms:status ?status ;
    task:operation ?operation ;
    dct:created ?created ;
    dct:modified ?modified;
    dct:creator ?creator .
}
ORDER BY DESC(?created)
LIMIT 100
```
5. switch consumers to 'normal operation' mode in `docker-compose.dev.yml` as described in the previous section.
6. Run `docker-compose up -d` to restart the stack
7. `./scripts/reset-elastic.sh` reset elastic search
Progression is visible via: `docker compose logs search -tf --tail=100`
8. The app should now be available at `http://localhost`

### Bestuursorganen Report

The report is generated every Sunday at 23:00. The report is available at `/download-exports/exports/Bestuursorganen`.

#### Trigger report generation manually

First you need to find the IP address of the `generate-reports` service. You can do this by running `docker inspect app-burgernabije-besluitendatabank-report-generation-1 | grep IPAddress`. Then use the IP address in the following command:
```bash
curl --header "Content-Type: application/json" --request POST --data '{"data":{"attributes":{"reportName":"governing-body-report"}}}' $IPAddress/reports
```

## Reference

### Models

This project is built around the following structure:
![Diagram for the relationship models](https://data.vlaanderen.be/doc/applicatieprofiel/besluit-publicatie/html/overview.jpg)

Source: [data.vlaanderen.be](https://data.vlaanderen.be/doc/applicatieprofiel/besluit-publicatie/)
