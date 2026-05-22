.. toctree::
    :maxdepth: 2
    :caption: Contents

Sacrifice to Sphinx
===================
Amen.

Description
===========
The OTOBO AI package is the OTOBO extension to interface with the otobo-ai-services for Retrieval-Augmented Generation (RAG).
It allows for data ingestion into the RAG as well as fetching answers from the RAG and providing an answer template containing the LLM generated answer.

See `the offical documentation <https://doc.otobo.org/manual/ai/11.0/en/content/index.html>`__ for more information.

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

The whole OTOBO AI Solution consists of 3 components:

- The OTOBO AI Extension package (this module)
- The OTOBO AI Services docker container providing the Vector DB
- A LLM for the actual RAG generation

See `the offical documentation <https://doc.otobo.org/manual/ai/11.0/en/content/index.html>`__ for an overview.


Setup
-----

.. important:: Requirement:
   In order to make use of this package you need to run the OTOBO AI Services docker container first.
   Here: https://github.com/RotherOSS/otobo-ai-services


Web Services
^^^^^^^^^^^^

All communication with the otobo-ai-services container is done via web service calls.

- Verify the AI Webservice invokers have been installed properly at - go to ``Admin UI -> Webservices -> Edit Web Service: OTOBO-AI``.
- In order to add authentication navigate to ``Otobo as Requester -> Configure``.
  Here, add a ``Common Header`` at the bottom of the page.
  Set ``Header Name`` to ``Authorization`` and  ``Header Value`` to ``apikey <OTOBO_AI_API_KEY>``.

Example screenshot:

.. image:: ../images/headers.png

.. note::
   The value for the header is literally the string ``apikey``, followed by a whitespace, followed by your custom API key.

Review and modify the ingestion parameters for tickets, FAQ and documents in the System Configuration under ``Core::OTOBOAI``.
At least you have to configure these two settings:

- ``OTOBOAI::Ticket::SearchRestrictions###0100-Default`` - Hash of `TicketSearch <https://github.com/RotherOSS/otobo/blob/rel-11_0/Kernel/System/Ticket/TicketSearch.pm#L46>`_ parameters.
     This Sysconfig can be used for the most basic default parameters.
     For more complicated setups create a ``OTOBOAI::Ticket::SearchRestrictions`` key in ``Config.pm`` and provide the ``TicketSearch`` hash in code
- ``OTOBOAI::FAQ::SearchRestrictions###0100-Default`` - Hash of `FAQSearch <https://github.com/RotherOSS/FAQ/blob/master/Kernel/System/FAQSearch.pm#L44>`_ parameters.
     This Sysconfig can be used for the most basic default parmeters.
     For more complicated setups create a ``OTOBOAI::FAQ::SearchRestrictions`` key in ``Config.pm`` and provide the ``FAQSearch`` hash in code.

The package installs a ticket event module, as well.
This module triggers an asynchronous request to the otobo-ai-services to provide content for a response template.
By default, the event is executed upon the ``ArticleCreate`` event, but the trigger is configurable via system configuration (check ``Ticket::EventModulePost###8000-PopulateOTOBOAIDynamicField``).

.. note::
   In case of an event which does not pass an article id, an attempt is made to retrieve the latest customer article of the ticket as base for the request.


Test otobo-ai-services web service
"""""""""""""""""""""""""""""""""""

In order to call the default RAG endpoint of the otobo-ai-services container, you can use the following curl command:

::

   curl -v 'http://otobo-ai:8000/otobo-ai/default/invoke' -H'Authorization: apikey <OTOBO_AI_API_KEY>'
   -H 'Content-Type: application/json' -d '{ "input" : { "question": "Tell me about Shakespeare", "do_scoring" : true }, "config" : {}, "kwargs" : {} }'

Obtaining an answer from the RAG endpoint confirms that the otobo-ai-services container is running and properly configured to receive requests.



Answer Template
^^^^^^^^^^^^^^^

In order to access the generated answer and reply to customer, this package provides an answer template ``OTOBOAI Answer Template`` which can be used in the agent interface.
The actual generated answer is stored in a dynamic field, which can be added to the template output.
It can be included by notification tag ``<OTOBO_AIAnswer_OTOBOAI>``.
You may create multiple answer templates with different output and use them for different purposes, e.g., one for customer communication and one for internal use only with more technical details.
Assign it to the queues relevant.

.. note::
   The name of the field may be configured via system configuration (check ``OTOBOAI::DynamicFieldOTOBOAI``).



Console Commands
================

``Maint::AI::GetAnswer``

::

   bin/otobo.Console.pl Maint::AI::GetAnswer --help

   Retrieve an AI generated answer from the otobo-ai-services container.

   Usage:
    otobo.Console.pl Maint::AI::GetAnswer [--article-id ...] [--ticket-id ...] [--question ...]

   Options:
    [--article-id ...]             - ArticleID
    [--ticket-id ...]              - TicketID
    [--question ...]               - Question
    [..rag ...]                    - The rag to use, defaults to 'OTOBOAI::DefaultRAG' sysconfig setting
    [--help|h]                     - Display help for this command.
    [--no-ansi]                    - Do not perform ANSI terminal output coloring.
    [--quiet]                      - Suppress informative output, only retain error messages.


``Maint::AI::Import``

::

   bin/otobo.Console.pl Maint::AI::Import --help

   Import existing tickets and faq articles to the AI vector database.

   Usage:
    otobo.Console.pl Maint::AI::Import [--target ...] [--reimport] [--sample-nth ...] [--sample ...]

   Options:
    [--target ...]                 - Specify which objects will be migrated. t: Tickets; f: FAQ articles; d: documents. If not specified all sources will be handled.
    [--reimport]                   - Do a re-import, which means the AI vectorstore and fulltext postgres DBs will be purged.
    [--sample-nth ...]             - Only relevant with --do-scoring, specifies the sample size. Take every nth num for sampling. Specifying 10 will take every tenth, resulting in a 10% sample size. Specify 5 to take every 5th which will give 20% Sampelsize. Specify 20 to take every 20th which will yield 5% sample size. The default is 10.
    [--sample ...]                 - Specify a file path to write a sample.json file containing TicketIDs to sample. When specified, then severy sample-nth Ticket will not be imported, but added to the list of sample ids. The default for sample-nth is 10 to sample every 10th Ticket (10% sample size). Override with the --sample-nth parameter.
    [--reference ...]              - Specify a path to an existimg sample.json file and use that for holding back the sample
    [--help|h]                     - Display help for this command.
    [--no-ansi]                    - Do not perform ANSI terminal output coloring.
    [--quiet]                      - Suppress informative output, only retain error messages.

``Maint::AI::Scoring``

::

   bin/otobo.Console.pl Maint::AI::Scoring --help

   Do a quality evaluation and write the coring result into a file

   Usage:
    otobo.Console.pl Maint::AI::Scoring [--sample ...] [--result ...] [--verbose] [--limit ...]

   Options:
    [--sample ...]                 - Specify wfile path to sample.json file with the TicketIDs to sample. This file can be produced by the 'Maint::AI::Import' console command using the --sample option.
    [--result ...]                 - Specify the file path for the scoring output should be written to in CSV (tab separated) format.
    [--json]                       - when scoring, report verbosely for each ticket processed as JSON and write it to that file.
    [--limit ...]                  - when scoring, max number of ticket ids to take from sample.
    [--help|h]                     - Display help for this command.
    [--no-ansi]                    - Do not perform ANSI terminal output coloring.
    [--quiet]                      - Suppress informative output, only retain error messages.
    [--use-case]                   - Use case to use for sampling. Defaults to 'Default'.



Configuration Reference
-----------------------


Ticket::EventModulePost###8000-PopulateOTOBOAIDynamicField
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Event module registration. For more performance you can define a trigger event (e. g. Event => TicketCreate). This is only possible if all Ticket dynamic fields need the same event.


Core::OTOBOAI
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

OTOBOAI::FAQ::SearchRestrictions###0100-Default
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which FAQ articles to include for FAQ ingestion.

OTOBOAI::Document::SearchRestrictions###0100-Default
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Which documents to include for AI search ingestion.

OTOBOAI::Ticket::SearchRestrictions###0100-Default
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Add search restrictions or params, to add not all tickets in the otobo ai vector database.

OTOBOAI::AllowedArticleSenderTypes
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Valid SenderTypes for Article selection when indexing and importing into AI. Valid values are "agent", "customer", and
"system". By default this contains only customer and agent.

OTOBOAI::OnlyVisibleForCustomer
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Allow only Articles visible for Customer to be embedded for AI

OTOBOAI::AnswerTemplateRequestType
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Define if fetching the AI answer on opening the Answer template should run synchronous (blocking) or asynchronous
which requires browser reload while answer is pending.

OTOBOAI::OverwritePreviousResponse
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
By activating this option, previous AI answers fetched for an article are ignored and a new request to the LLM is started.
Activating this setting currently makes only sense with `OTOBOAI::AnswerTemplateRequestType` set to
'synchronous'.

OTOBOAI::Placeholder
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Define a string which is used as a placeholder while waiting for the AI answer.

OTOBOAI::StripSignatureRegex
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Regex to strip Signatures from Article Bodies, if endabled.

OTOBOAI::DynamicFieldOTOBOAI
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
This option defines the dynamic field in which an OTOBOAI answer is stored.


Daemon::SchedulerCronTaskManager::Task
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Daemon::SchedulerCronTaskManager::Task###RebuildOtoboAIIndex
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Rebuilds the Otobo AI Vector DB index.


Otobo AI Dashboard
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
