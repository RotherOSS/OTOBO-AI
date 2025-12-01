.. toctree::
    :maxdepth: 2
    :caption: Contents

Sacrifice to Sphinx
===================

Description
===========
The OTOBO AI package is the OTOBO extension to interface with Large Language Model (LLM) for Retrieval-Augmented Generation (RAG).

System requirements
===================

Framework
---------
OTOBO 11.0.x

Packages
--------
\-

Third-party software
--------------------
\-

Usage
=====
This package adds support for storing Ticket, FAQ, and Document data in a Vector DB and using an LLM to generate Response Proposal via RAG.

The whole OTOBO AI Solution consists of 3 Components:

- The OTBO AI Extension package (this module)
- The OTOBO AI Services docker container providing the Vector DB
- A LLM for the actual RAG generation

Setup
-----
In order to make use of this package you need to run the OTOBO AI Services docker container first. Please resort to the documentation if OTOBO AI Services for more details, but as a quick guide:

Otobo-ai-services
-----------------

**Note:** *Preliminary documentation, this assumes you start the otobo-ai-services container from it's own docker-compose.yml, but this is likely to change*

- Get the OTOBO AI services container from https://github.com/RotherOSS/otobo-ai-services/
- switch to branch mvp_purge # TODO: this is current dev
- create a rags folder in the root directory
- copy the rag_examples/tfd_rag1 folder into the rags folder
- copy the `.env_example` file to `.env`
- edit the `.env` file and set the OTOBO_AI_API_KEY to something of your liking
- start up container with `docker compose up -d`

Test LLM connectivity
---------------------

Run this from the host where the otobo-ai-services container runs, and optionally also inside the container.

::

    curl -v http://ai.local.rother-oss.com:11434/api/generate -d '{ "model": "llama3.3:70b", "prompt": "Tell me about Shakespeare." }'

You should see a stream of text chunks coming back from the LLM


Test otobo-ai-services web service
----------------------------------

::
   
   curl -v 'http://otobo-ai:8000/otobo-ai/tfd_rag1/invoke' -H'Authorization: apikey <OTOBO_AI_API_KEY>' 
   -H 'Content-Type: application/json' -d '{ "input" : { "question": "Tell me about Shakespeare", "do_scoring" : true }, "config" : {}, "kwargs" : {} }'

You should see `Weiterleiten an Kundenservice` returned as result, which is the default answer if no context available for thequestion.


Otobo-ai extension package
--------------------------

- Install this package as usual via OTOBO Package Manager in the Admin UI.
- Verify the AI Webservice invokers have been installed properly at - go to Admin UI -> Webservices -> Edit Web Service: OTOBO-AI
- Add authentication by going to ‘Otobo as Requester’ -> Configure. Here, add a ‘Common Header’ at the bottom of the page. Set `Header Name` to 'Authorization'. Set `Header Value` to 'apikey <OTOBO_AI_API_KEY>'
- Review and modify the Ingestion Parameters for Tickets, FAQ and Docs in the System Configuration under `Core::OTOBOAI`

**Note:** The value for the Header is literally the string “apikey”, followed by a whitespace, followed by your custom API key.

The package as well installs a ticket event module. This module triggers an asynchronous request to the LLM to provide content for a response template. Per default, the event is executed upon ArticleCreate, but the trigger is configurable via system configuration.

Note that in case of an event which does not pass an article id, an attempt is made to retrieve the latest customer article of the ticket as base for the request.

Configuration Reference
-----------------------

Core::DynamicFields::DriverRegistration
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

DynamicFields::Driver###TextAreaAI
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
DynamicField backend registration.

Core::Event::Ticket
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Ticket::EventModulePost###8000-PopulateOTOBOAIDynamicField
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Event module registration. For more performance you can define a trigger event (e. g. Event => TicketCreate). This is only possible if all Ticket dynamic fields need the same event.

Core::OTOBOAI
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

OTOBOAI::AnswerTemplateRequestType
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Define if fetching the AI answer on opening the Answer template should run synchronous or asynchronous.

OTOBOAI::Document::SearchRestrictions
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which documents to include for AI search ingestion.

OTOBOAI::DynamicFieldOTOBOAI
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
This option defines the dynamic field in which an OTOBOAI answer is stored.

OTOBOAI::FAQ::SearchRestrictions
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which FAQ articles to include for FAQ ingestion.

OTOBOAI::OverwritePreviousResponse
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
By activating this option, previous AI answers fetched for an article are ignored and a new request to the LLM is started.

OTOBOAI::Placeholder
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Define a string which is used as a placeholder while waiting for the AI answer.

OTOBOAI::Ticket::Chunks
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which articles to include for ticket chunk ingestion.

OTOBOAI::Ticket::SearchRestrictions
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Add search restrictions or params, to add not all tickets in the otobo ai vector database.

Daemon::SchedulerCronTaskManager::Task
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Daemon::SchedulerCronTaskManager::Task###RebuildOtoboAIIndex
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Rebuilds the Otobo AI Vector DB index.

Frontend::Admin::ModuleRegistration
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Frontend::Module###AdminDynamicFieldTextAreaAI
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Frontend module registration for the agent interface.

Frontend::Admin::ModuleRegistration::Loader
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Loader::Module::AdminDynamicFieldTextAreaAI###003-OTOBOAI
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Loader module registration for the agent interface.

Frontend::Agent::ModuleRegistration
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Frontend::Module###OtoboAIDashboard
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Frontend module registration for the agent interface.

Frontend::Agent::ModuleRegistration::Loader
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Loader::Module::AgentDashboard###0160-OTOBOAIDashboard
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Loader module registration for the agent interface.

Frontend::Agent::View::Dashboard
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

DashboardBackend###0160-OTOBOAIDashboard
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Parameters for the dashboard backend of the tickets overview by search template of the agent interface. "Limit" is the number of entries shown by default. "Group" is used to restrict the access to the plugin (e. g. Group: admin;group1;group2;). "Default" determines if the plugin is enabled by default or if the user needs to enable it manually. "CacheTTLLocal" is the cache time in minutes for the plugin. "Mandatory" determines if the plugin is always shown and can not be removed by agents. Note: Only Ticket attributes and Dynamic Fields (DynamicField_NameX) are allowed for DefaultColumns.

OtoboAIDashboard::Frontend::CacheTTL
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Number of hours of TTL for the Otobo-AI cache elements.

OtoboAIDashboard::Frontend::PollingInterval
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Number of seconds on the client side between attempts to get a cached answer.

OtoboAIDashboard::Frontend::TextAreaQuestion
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Permitted width for compose question windows.

OtoboAIDashboard::Frontend::TimeoutInterval
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Timeout to consider that a request has no response.

GenericInterface::Invoker::ModuleRegistration
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

GenericInterface::Invoker::Module###OTOBOAI::GetAnswer
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
GenericInterface module registration for the invoker layer.

GenericInterface::Invoker::Module###OTOBOAI::IngestMany
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
GenericInterface module registration for the invoker layer.

GenericInterface::Invoker::Module###OTOBOAI::Purge
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
GenericInterface module registration for the invoker layer.

About
=======

Contact
-------
| Rother OSS GmbH
| Email: hello@otobo.io
| Web: https://otobo.io

Version
-------
Author: |doc-vendor| / Version: |doc-version| / Date of release: |doc-datestamp|
