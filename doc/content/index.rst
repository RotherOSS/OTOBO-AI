.. toctree::
    :maxdepth: 2
    :caption: Contents

Sacrifice to Sphinx
===================

Description
===========
The Otobo AI package is the Otobo extension to interface with LLM for Retrieval-Augmented Generation (RAG)

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
This package adds support for storing Ticket, FAQ, and Document data in a Vector DB and using an LLM to
generate Response Proposal via RAG.

The whole Otobo AI Solution consists of 3 Components

- The Otobo AI Extension package (this module)
- The Otobo AI Services docker container providing the Vector DB
- A LLM for the actual RAG generation

Setup
-----
In order to make use of this package you need to run the Otobo AI Services docker container first.
Please resort to the documentation if Otobo AI Services for more details, but as a quick guide:


Otobo-ai-services
-----------------

**Note:** *Preliminary documentation, this assumes you start the otobo-ai-services container from it's 
own docker-compose.yml, but this is likely to change*

- Get the Otobo AI services container from https://github.com/RotherOSS/otobo-ai-services/
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

- Install this package as usual via Otobo Package Manager in the Admin UI.
- Verify the AI Webservice invokers have been installed properly at - go to Admin UI -> Webservices -> Edit Web Service: OTOBO-AI
- Add authentication by going to ‘Otobo as Requester’ -> Configure. Here, add a ‘Common Header’ at the bottom of the page. Set `Header Name` to 'Authorization'. Set `Header Value` to 'apikey <OTOBO_AI_API_KEY>'
- Review and modify the Ingestion Parameters for Tickets, FAQ and Docs in the System Configuration under `Core::OTOBOAI`


**Note:** The value for the Header is literally the string “apikey”, followed by a whitespace, followed by your custom API key.

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

OTOBOAI::Document::SearchRestrictions
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which documents to include for AI search ingestion.

OTOBOAI::FAQ::SearchRestrictions
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which FAQ articles to include for FAQ ingestion.

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
