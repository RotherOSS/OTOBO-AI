.. image:: ../images/otobo-logo.png
   :align: center

.. toctree::
    :maxdepth: 2
    :caption: Contents

Sacrifice to Sphinx
===================
.. This chapter must always be empty. Any content is lost when creating the final version of the documentation.

Overview
========
The Otobo AI package is the Otobo extension to interface with LLM for Retrieval-Augmented Generation (RAG)


Summary
-------

This package adds support for storing Ticket, FAQ, and Document data in a Vector DB and using an LLM to
generate Response Proposal via RAG.

The whole Otobo AI Solution consists of 3 Components

- The Otobo AI Extension package (this module)
- The Otobo AI Services docker container providing the Vector DB
- A LLM for the actual RAG generation


Configuration
=============

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


System Configuration Settings
-----------------------------

The following settings are available:

- OTOBOAI::Ticket::SearchRestrictions
- OTOBOAI::Ticket::Chunks
- OTOBOAI::FAQ::SearchRestrictions
- OTOBOAI::Document::SearchRestrictions

**Note:** You need to review and adjust those settings to match your needs!


Otobo AI Context Data Ingestion
===============================

Import Otobo Data into the vector DB:

::

   bin/otobo.Console.pl Maint::AI::Import --reimport


After a successful ingestion run, the RAG process can be tested with the following command line:

::

   bin/otobo.Console.pl Maint::AI::GetAnswer --question 'Tell me about Shakespeare'

If you ask a question that is not part of the context, the AI will answer with it's default answer, which is:   
' Weiterleiten an Kundenservice'


Otobo Dynamic Field Config
==========================

Installing the otobo-ai extension package will automatically install the OtoboAI Dynamic Field as an internal Dynamic Field for 
articles.

The async RAG retrieval process is initiated by a configurable event:

::

    <Setting Name="Ticket::EventModulePost###8000-PopulateOTOBOAIDynamicField" Required="0" Valid="1">
        <Description Translatable="1">Event module registration. For more performance you can define a trigger event (e. g. Event =&gt; TicketCreate). This is only possible if all Ticket dynamic fields need the same event.</Description>
        <Navigation>Core::Event::Ticket</Navigation>
        <Value>
            <Hash>
                <Item Key="Module">Kernel::System::Ticket::Event::PopulateOTOBOAIDynamicField</Item>
                <Item Key="Event">ArticleCreate</Item>
                <Item Key="Transaction">1</Item>
                <Item Key="Queues">
                    <Array>
                    </Array>
                </Item>
            </Hash>
        </Value>
    </Setting>

For Article events, the triggering article will be used as Question for the AI solutions. If configured for Ticket Events that do 
no send an ArticleID, the fallback is to use the last article from Customer as the Question.


Otobo RAG based Response Template
=================================

The Otobo AI extension package installs two RAG Answer templates by default:

- OTOBOAI Answer Template [EN]
- OTOBOAI Answer Template [DE]

RAG Templates are standard templates that contain the Otobo Replacement Tag `<OTOBO_AIAnswer_OTOBOAI>` which will be replaced with the actual RAG answer from the LLM.


System requirements
-------------------

Framework
^^^^^^^^^

OTOBO 11.0.x

Packages
^^^^^^^^

This package does not depend on other Otobo packages.


Third-party software
^^^^^^^^^^^^^^^^^^^^


Further Reading
---------------


About
=======

Contact
-------
| Rother OSS GmbH
| Email: hello@otobo.io
| Web: https://otobo.io

Version
-------
