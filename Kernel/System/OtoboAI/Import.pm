# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::System::OtoboAI::Import;

use strict;
use warnings;

use Path::Class    qw(file);
use File::Find     qw(find);
use File::Basename qw(dirname);
use JSON           qw(encode_json from_json);
use Storable       qw(dclone);

use Kernel::System::VariableCheck qw(:all);

use parent qw(Kernel::System::AsynchronousExecutor);

our @ObjectDependencies = (
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Log',
    'Kernel::Config',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::GenericInterface::Requester',
    'Kernel::System::Package',
    'Kernel::System::FAQ',
    'Kernel::System::HTMLUtils',
);

=head1 NAME

Kernel::System::OtoboAI::Import - ingest Tickets or FAQs

=head1 DESCRIPTION

call OtoboAI Import synchronously or asynchronously

=head2 new()

create an Import object. Do not use it directly, instead use:

    my $ImportObject = $Kernel::OM->Get('Kernel::System::OtoboAI::Import');

=cut

sub new {

    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    $Self->InitImport();

    return $Self;
}

sub InitImport() {
    my ( $Self, %Param ) = @_;

    # check whether the AI web service is enabled and if not, activate it
    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $AIWebservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "OTOBO-AI webservice not found!",
        );
        die;
    }

    # Set the webservice id
    $Self->{WebserviceID} = $AIWebservice->{ID};

    if ( $AIWebservice->{ValidID} != 1 ) {
        my $Success = $WebserviceObject->WebserviceUpdate(
            %{$AIWebservice},
            ValidID => 1,
            UserID  => 1,
        );

        if ( !$Success ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "OTOBO-AI webservice could not be activated!",
            );
            die;
        }
    }

    # fetch config
    my $StripSignatureRegEx = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::StripSignatureRegex');
    if ($StripSignatureRegEx) {

        my $Regex = qr/$StripSignatureRegEx/m;
        $Self->{StripSignatureRegEx} = $Regex;
    }

    return;
}

=head2 MigrateTickets()

Synchronize the OTOBO-AI vector DB with the updated states of one or more Tickets for one or more use-cases.

returns 1 if successful or undef otherwise

    my $Success = $Object->MigrateTickets(
        TicketID => 123,                        # optional, consider only this ticket for migration
        UseCases => [                           # optional, consider only these use-cases for migration
            'default',
            'sales',
        ],
        Sample       => '/home/sample.json',    # optional, file path or directory to write a sample.json containing TicketIDs to sample
        SampleNth    => 10,                     # optional, sample size (default: 10)
        Reference    => '/home/sample.json',    # optional, path to an existing sample.json containing TicketIDs to reference
        Asynchronous => 0,                      # optional, do not manually set this, unless you are explicitly
                                                # running the Requester in an asynchronous context (default: 0)
        Console      => $ConsoleObject,         # optional, give realtime status updates on the migration process (assumes print to STDOUT)
    );

=cut

sub MigrateTickets {
    my ( $Self, %Param ) = @_;

    $Self->InitImport();

    my $UseCases     = $Param{UseCases};
    my $Sample       = $Param{Sample};
    my $SampleNth    = $Param{SampleNth} || 10;
    my $Reference    = $Param{Reference};
    my $Asynchronous = $Param{Asynchronous};
    my $Console      = $Param{Console} && $Param{Console}->can('Print') ? $Param{Console} : undef;

    my $BatchSize = 100;

    # handle sample option for console command
    if ($Sample) {

        my $FullPath = $Sample;

        if ( -d $Sample ) {
            $FullPath .= "/sample.json";
        }

        $Self->{SamplePath} = $FullPath;

        my $SampleDir = dirname($FullPath);
        if ( !-d $SampleDir ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "do-sample parameter needs a valid path to an output file, but parent path " . $SampleDir . " does not exist.",
            );
            die;
        }
    }

    if ( $Reference && -e $Reference ) {

        my $RefIDsJSON = file($Reference)->slurp;
        $Self->{RefIDs} = from_json($RefIDsJSON);
    }

    my $TicketObject    = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject   = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my $OnlyVisibleForCustomer    = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::OnlyVisibleForCustomer') // 1;
    my $AllowedArticleSenderTypes = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::AllowedArticleSenderTypes');
    my $SearchRestrictionsHash    = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Ticket::SearchRestrictions') // {};

    if ($Console) {
        $Console->Print("<green>Ingesting Tickets ...</green>\n");
    }

    my %TicketSample;

    SEARCHRESTRICTION:
    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );

        my $IncludeUseCase = 0;
        if ( $UseCases && scalar $UseCases->@* ) {

            $IncludeUseCase = grep { $_ eq $SearchRestrictionsKey } $UseCases->@*;
        }
        else {
            $IncludeUseCase = 1;
        }

        next SEARCHRESTRICTION if $IncludeUseCase == 0;

        my @UseCaseLabels = ( delete $SearchRestrictions->{Label} )->@*;

        if ( !exists $TicketSample{$SearchRestrictionsKey} ) {
            $TicketSample{$SearchRestrictionsKey} = [];
        }

        if ($Console) {
            $Console->Print("<yellow>Use Case: $SearchRestrictionsKey.</yellow>\n");
        }

        # remove search parameters with empty arrays as they prevent search results entirely
        for my $ArrayParam (qw(Queues Services StateTypes Types)) {
            if ( !IsArrayRefWithData( $SearchRestrictions->{$ArrayParam} ) ) {
                delete $SearchRestrictions->{$ArrayParam};
            }
        }

        # fetch all TicketIDs satisfying this search restriction
        my @TicketIDs = $TicketObject->TicketSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
            TicketID   => $Param{TicketID},
            %{$SearchRestrictions},
        );

        my $Errors = 0;
        my $Count  = 0;

        # only required for console command
        my $Handled   = 0;
        my $Imported  = 0;
        my $Percent10 = ( sort { $a <=> $b } ( 10, int( scalar(@TicketIDs) / 10 ) ) )[1];
        my $Percent1  = ( sort { $a <=> $b } ( 1,  int( scalar(@TicketIDs) / 100 ) ) )[1];

        if ($Console) {
            $Console->Print(
                "<yellow>" . ( scalar @TicketIDs ) . " Tickets are considered for transfer. This can take several hours, depending on the number of tickets.</yellow>\n"
            );
        }

        BATCH:
        while ( $Count < scalar @TicketIDs ) {
            my $Until = $Count + $BatchSize - 1;
            if ( $Until > $#TicketIDs ) {
                $Until = $#TicketIDs;
            }
            my @Batch = @TicketIDs[ $Count .. $Until ];

            my @ImportTicketsQA;
            my @ImportTicketsAgentArticles;

            TICKETID:
            for my $TicketID (@Batch) {

                # show progress
                if ($Console) {
                    if ( $Count && $Count % $Percent10 == 0 ) {
                        my $Percent = int( $Count / ( scalar(@TicketIDs) / 100 ) );
                        $Console->Print(
                            "<yellow>$Count</yellow> of <yellow>"
                                . scalar(@TicketIDs)
                                . "</yellow> processed (<yellow>$Percent %</yellow> done. $Handled Tickets handled, $Imported Tickets imported).\n"
                        );
                    }
                    elsif ( scalar(@TicketIDs) > 50 && $Count % $Percent1 == 0 ) {
                        $Console->Print('. ');
                        select()->flush();    # show the dot immediately, beware this assumes ConsoleObject prints to STDOUT
                    }
                }

                $Count++;

                my @Articles = $ArticleObject->ArticleList(
                    TicketID => $TicketID,
                );

                if ($Reference) {

                    my $IsPartOfSample = grep { $_ eq "$TicketID" } $Self->{RefIDs}->{$SearchRestrictionsKey}->@*;
                    next TICKETID if ($IsPartOfSample);
                }

                next TICKETID if !@Articles;

                my %SenderLookup = map { $_ => $ArticleObject->ArticleSenderTypeLookup( SenderType => $_ ) } qw/agent customer/;

                # SelectionRule: only consider tickets started by a customer
                next TICKETID if $Articles[0]{SenderTypeID} ne $SenderLookup{customer};

                my $QuestionArticle = shift @Articles;
                my @AnswerArticles;

                if ($Sample) {

                    # keep 10% sample of tickets for testing and do NOT import them

                    if ( $Handled % $SampleNth == 0 ) {

                        $Handled++;
                        push $TicketSample{$SearchRestrictionsKey}->@*, $TicketID;
                        next TICKETID;
                    }
                }

                ARTICLE:
                for my $Article (@Articles) {

                    # SelectionRule: skip tickets where the customer sent info twice without any agent interference
                    next TICKETID if $Article->{SenderTypeID} eq $SenderLookup{customer} && !@AnswerArticles;

                    # SelectionRule: skip articles if they are not customer visible
                    if ($OnlyVisibleForCustomer) {
                        next ARTICLE if $Article->{IsVisibleForCustomer} ne 1;
                    }

                    # SelectionRule: skip articles if their sendertype is not on the whitelist (if enabled)
                    if ($AllowedArticleSenderTypes) {
                        my $Allowed = 0;
                        TYPES:
                        for my $Type ( $AllowedArticleSenderTypes->@* ) {
                            if ( $SenderLookup{$Type} == $Article->{SenderTypeID} ) {
                                $Allowed = 1;
                                last TYPES;
                            }
                        }
                        if ( !$Allowed ) {
                            next ARTICLE;
                        }
                    }

                    push @AnswerArticles, $Article;
                }

                next TICKETID if !@AnswerArticles;

                {
                    my $ArticleBackend = $ArticleObject->BackendForArticle(
                        TicketID  => $TicketID,
                        ArticleID => $QuestionArticle->{ArticleID},
                    );

                    my %Article = $ArticleBackend->ArticleGet(
                        TicketID  => $TicketID,
                        ArticleID => $QuestionArticle->{ArticleID},
                    );

                    next TICKETID if !$Article{Body};

                    $QuestionArticle = \%Article;
                }

                my @AnswerArticlesWithBody;

                ANSWER:
                for my $i ( 0 .. $#AnswerArticles ) {
                    my $ArticleBackend = $ArticleObject->BackendForArticle(
                        TicketID  => $TicketID,
                        ArticleID => $AnswerArticles[$i]{ArticleID},
                    );

                    my %Article = $ArticleBackend->ArticleGet(
                        TicketID  => $TicketID,
                        ArticleID => $AnswerArticles[$i]{ArticleID},
                    );

                    next ANSWER if !$Article{Body};

                    # SelectionRule: Remove citations from agent articles
                    $Article{Body} =~ s/^\s*>.+?$//msg;

                    push @AnswerArticlesWithBody, \%Article;
                }

                next TICKETID if !@AnswerArticlesWithBody;

                $Handled++;
                $Imported++;

                my $QuestionSubject = $QuestionArticle->{Subject}         // '';
                my $QuestionBody    = $QuestionArticle->{Body}            // '';
                my $AnswerSubject   = $AnswerArticlesWithBody[0]{Subject} // '';
                my $AnswerBody      = $AnswerArticlesWithBody[0]{Body};

                $QuestionBody = $Self->StripSignature( Body => $QuestionBody );
                $AnswerBody   = $Self->StripSignature( Body => $AnswerBody );

                my $ImportQATicket = {
                    "source_id"     => $TicketID,
                    "content_items" => [
                        {
                            type => 'question',
                            text => $QuestionSubject . '. ' . $QuestionBody,
                        },
                        {
                            type => 'answer',
                            text => $AnswerSubject . '. ' . $AnswerBody,
                        },
                    ]
                };

                $ImportQATicket->{labels} = \@UseCaseLabels;

                push @ImportTicketsQA, $ImportQATicket;

                my @ContentItems;
                for my $AnswerArticleWithBody (@AnswerArticlesWithBody) {

                    my $Subject = $AnswerArticleWithBody->{Subject} // '';
                    my $Body    = $AnswerArticleWithBody->{Body}    // '';

                    $Body = $Self->StripSignature( Body => $Body );
                    push @ContentItems, {
                        type => 'text',
                        text => $Subject . '. ' . $Body,
                    };
                }

                my $ImportAgentArticles = {
                    "source_id"     => $TicketID,
                    "content_items" => \@ContentItems,
                };

                $ImportAgentArticles->{labels} = \@UseCaseLabels;

                push @ImportTicketsAgentArticles, $ImportAgentArticles;
            }

            my $Result;
            if (@ImportTicketsQA) {

                # Ingest Q/A articles
                $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => $Asynchronous,
                    Data         => {
                        Type    => 'ticket_pairs',      # currently supported: faq, documentation, ticket_pairs, ticket_chunks
                        Content => \@ImportTicketsQA,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;

                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => "Failed to ingest Q/A article pairs: " . $Result->{ErrorMessage},
                    );

                    if ($Console) {
                        $Console->Print( "<red>Error importing Tickets: " . $Result->{ErrorMessage} . "</red>\n" );
                    }
                }
            }

            if (@ImportTicketsAgentArticles) {

                # Ingest agent articles
                $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => $Asynchronous,
                    Data         => {
                        Type    => 'ticket_chunks',
                        Content => \@ImportTicketsAgentArticles,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;

                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => "Failed to ingest agent articles: " . $Result->{ErrorMessage},
                    );

                    if ($Console) {
                        $Console->Print( "<red>Error importing Tickets: " . $Result->{ErrorMessage} . "</red>\n" );
                    }
                }
            }
        }

        if ($Errors) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Ticket transfer complete. ' . $Errors . ' error(s) occurred!',
            );

            if ($Console) {
                $Console->Print("<yellow>Ticket transfer complete. $Errors error(s) occurred!</yellow>\n");
            }
        }
        else {
            if ($Console) {
                $Console->Print("<green>Ticket transfer complete. Considered $Count tickets, of wich $Imported where imported.</green>\n");
            }
        }
    }

    if ($Sample) {

        my $JSON = encode_json( \%TicketSample );
        file( $Self->{SamplePath} )->spew($JSON);
    }

    return 1;
}

sub MigrateTicketsAsync {
    my ( $Self, %Param ) = @_;

    # let the requester know it is run in an asynchronous context
    $Param{Asynchronous} = 1;

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI::Import::MigrateTicketsAsync call initiated.",
    );

    my $Success = $Self->AsyncCall(
        ObjectName               => 'Kernel::System::OtoboAI::Import',
        FunctionName             => 'MigrateTickets',
        FunctionParams           => \%Param,
        Attempts                 => 1,
        MaximumParallelInstances => 0,
    );

    if ( !$Success ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Initialize async call failed!",
        );
        return;
    }

    return 1;
}

=head2 MigrateFAQs()

Synchronize the OTOBO-AI vector DB with the updated states of one or more FAQ items for one or more use-cases.

returns 1 if successful or undef otherwise

    my $Success = $Object->MigrateFAQs(
        FAQID    => 123,                   # optional, consider only this FAQ item for migration
        UseCases => [                      # optional, consider only these use-cases for migration
            'default',
            'sales',
        ],
        Asynchronous => 0,                 # optional, do not manually set this, unless you are explicitly
                                           # running the Requester in an asynchronous context (default: 0)
        Console      => $ConsoleObject,    # optional, give realtime status updates on the migration process (assumes print to STDOUT)
    );

=cut

sub MigrateFAQs {
    my ( $Self, %Param ) = @_;

    $Self->InitImport();

    my $UseCases     = $Param{UseCases};
    my $Asynchronous = $Param{Asynchronous};
    my $Console      = $Param{Console} && $Param{Console}->can('Print') ? $Param{Console} : undef;

    # check whether FAQ package is installed
    my $PackageObject = $Kernel::OM->Get('Kernel::System::Package');
    my $IsInstalled   = $PackageObject->PackageIsInstalled(
        Name => 'FAQ',
    );
    if ( !$IsInstalled ) {
        if ($Console) {
            $Console->Print("<yellow>Skipping FAQ articles (FAQ not installed)...</yellow>\n");
        }

        return 1;
    }

    if ($Console) {
        $Console->Print("<green>Ingesting FAQs ...</green>\n");
    }

    # prepare the import
    my $FAQObject       = $Kernel::OM->Get('Kernel::System::FAQ');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');
    my $HTMLUtilsObject = $Kernel::OM->Get('Kernel::System::HTMLUtils');

    # determine search restrictions for FAQSearch
    my $SearchRestrictionsHash = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::FAQ::SearchRestrictions') // {};

    SEARCHRESTRICTION:
    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;

        my $IncludeUseCase = 0;
        if ( $UseCases && scalar $UseCases->@* ) {

            $IncludeUseCase = grep { $_ eq $SearchRestrictionsKey } $UseCases->@*;
        }
        else {
            $IncludeUseCase = 1;
        }

        next SEARCHRESTRICTION if $IncludeUseCase == 0;

        if ($Console) {
            $Console->Print("<yellow>Use Case: $SearchRestrictionsKey</yellow>\n");
        }

        # fetch all FAQIDs satisfying this search restriction
        my @FAQIDs = $FAQObject->FAQSearch(
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
            FAQID      => $Param{FAQID},
            %{$SearchRestrictions},
        );

        # iterate over the faqs
        my $Count     = 0;
        my $Percent10 = ( sort { $a <=> $b } ( 10, int( scalar(@FAQIDs) / 10 ) ) )[1];
        my $Percent1  = ( sort { $a <=> $b } ( 1,  int( scalar(@FAQIDs) / 100 ) ) )[1];

        if ( scalar(@FAQIDs) > 100 && $Console ) {
            $Console->Print("<yellow>FAQ article are transferred. This can take several hours, depending on the number of faq article.</yellow>\n");
        }

        my $Errors = 0;
        my @FAQData;

        FAQID:
        for my $FAQID (@FAQIDs) {

            $Count++;

            my %FAQ = $FAQObject->FAQGet(
                ItemID        => $FAQID,
                ItemFields    => 1,        # Optional, default 0. To include the item field content for this
                                           # FAQ item on the return structure.
                DynamicFields => 0,        # Optional, default 0. To include the dynamic fields for this
                                           # FAQ item on the return structure.
                UserID        => 1,
            );

            # scrub HTML
            my $Question = $HTMLUtilsObject->ToAscii( String => $FAQ{Title} // '' )
                . ". " . $HTMLUtilsObject->ToAscii( String => $FAQ{Field1} // '' )
                . ". " . $HTMLUtilsObject->ToAscii( String => $FAQ{Field2} // '' );

            my $Answer = $HTMLUtilsObject->ToAscii( String => $FAQ{Field3} // '' );

            # prepare data item for invoker

            my $Data = {
                "source_id"     => "$FAQID",
                "content_items" => [
                    {
                        type => 'question',
                        text => $Question,
                    },
                    {
                        type => 'answer',
                        text => $Answer,
                    }
                ]
            };

            $Data->{labels} = \@UseCaseLabels;

            push @FAQData, $Data;

            # batches of 10 FAQs
            if ( $Count % 10 == 0 ) {

                # ingest
                my $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => $Asynchronous,
                    Data         => {
                        Type    => 'faqs',
                        Content => \@FAQData,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;

                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => "Error importing FAQs: " . $Result->{ErrorMessage},
                    );

                    if ($Console) {
                        $Console->Print( "<red>Error importing FAQs: " . $Result->{ErrorMessage} . "</red>\n" );
                    }
                }

                @FAQData = ();
            }

            # show progress and potentially sleep
            if ($Console) {
                if ( $Count % $Percent10 == 0 ) {
                    my $Percent = int( $Count / ( scalar(@FAQIDs) / 100 ) );
                    $Console->Print(
                        "<yellow>$Count</yellow> of <yellow>"
                            . scalar(@FAQIDs)
                            . "</yellow> processed (<yellow>$Percent %</yellow> done).\n"
                    );
                }
                elsif ( scalar(@FAQIDs) > 50 && $Count % $Percent1 == 0 ) {
                    $Console->Print('. ');
                    select()->flush();    # show the dot immediately, beware this assumes ConsoleObject prints to STDOUT
                }
            }
        }

        # ingest leftovers
        if (@FAQData) {

            my $Result = $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => $Asynchronous,
                Data         => {
                    Type    => 'faqs',
                    Content => \@FAQData,
                },
            );

            if ( !$Result->{Success} ) {
                $Errors++;

                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Error importing FAQs: " . $Result->{ErrorMessage},
                );

                if ($Console) {
                    $Console->Print( "<red>Error importing FAQs: " . $Result->{ErrorMessage} . "</red>\n" );
                }
            }
        }

        if ($Errors) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'FAQ transfer complete. ' . $Errors . ' error(s) occurred!',
            );

            if ($Console) {
                $Console->Print("<yellow>FAQ transfer complete. $Errors error(s) occurred!</yellow>\n");
            }
        }
        else {
            if ($Console) {
                $Console->Print("<green>FAQ transfer complete. Imported $Count FAQ items.</green>\n");
            }
        }
    }
    return 1;
}

sub MigrateFAQsAsync {
    my ( $Self, %Param ) = @_;

    # let the requester know it is run in an asynchronous context
    $Param{Asynchronous} = 1;

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI::Import::MigrateFAQsAsync call initiated.",
    );

    my $Success = $Self->AsyncCall(
        ObjectName               => 'Kernel::System::OtoboAI::Import',
        FunctionName             => 'MigrateFAQs',
        FunctionParams           => \%Param,
        Attempts                 => 1,
        MaximumParallelInstances => 0,
    );

    if ( !$Success ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Initialize async call failed!",
        );
        return;
    }

    return 1;
}

=head2 MigrateDocs()

Synchronize the OTOBO-AI vector DB with one or more documents for one or more use-cases.

returns 1 if successful or undef otherwise

    my $Success = $Object->MigrateDocs(
        UseCases => [                      # optional, consider only these use-cases for migration
            'default',
            'sales',
        ],
        Asynchronous => 0,                 # optional, do not manually set this, unless you are explicitly
                                           # running the Requester in an asynchronous context (default: 0)
        Console      => $ConsoleObject,    # optional, give realtime status updates on the migration process (assumes print to STDOUT)
    );

=cut

sub MigrateDocs {
    my ( $Self, %Param ) = @_;

    $Self->InitImport();

    my $UseCases     = $Param{UseCases};
    my $Asynchronous = $Param{Asynchronous};
    my $Console      = $Param{Console} && $Param{Console}->can('Print') ? $Param{Console} : undef;

    if ($Console) {
        $Console->Print("<green>Ingesting Documents ...</green>\n");
    }

    # prepare the import
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    # determine search restrictions for document search
    my $SearchRestrictionsHash = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Document::SearchRestrictions') // {};

    SEARCHRESTRICTION:
    for my $SearchRestrictionsKey ( keys $SearchRestrictionsHash->%* )
    {
        my $SearchRestrictions = dclone( $SearchRestrictionsHash->{$SearchRestrictionsKey} );
        my @UseCaseLabels      = ( delete $SearchRestrictions->{Label} )->@*;

        my $IncludeUseCase = 0;
        if ( $UseCases && scalar $UseCases->@* ) {

            $IncludeUseCase = grep { $_ eq $SearchRestrictionsKey } $UseCases->@*;
        }
        else {
            $IncludeUseCase = 1;
        }

        next SEARCHRESTRICTION if $IncludeUseCase == 0;

        if ($Console) {
            $Console->Print("<yellow>Use Case: $SearchRestrictionsKey</yellow>\n");
        }

        my $DocumentPaths = $Self->_DocumentSearch(
            %$SearchRestrictions,
            Console => $Console,
        );

        my @Content;
        my $Count  = 0;
        my $Errors = 0;

        DOCUMENT:
        for my $DocumentPath (@$DocumentPaths) {

            $Count++;

            # slurp content of file
            my $FileContent = file($DocumentPath)->slurp( iomode => '<:encoding(UTF-8)' ) // '';

            my $Data = {
                "source_id"     => $DocumentPath,
                "content_items" => [
                    {
                        type => 'text',
                        text => $FileContent,
                    }
                ]
            };

            $Data->{labels} = \@UseCaseLabels;

            push @Content, $Data;

            # ingest in batches of 10
            if ( $Count % 10 == 0 ) {

                # ingest
                my $Result = $RequesterObject->Run(
                    WebserviceID => $Self->{WebserviceID},
                    Invoker      => 'IngestMany',
                    Asynchronous => $Asynchronous,
                    Data         => {
                        Type    => 'docs',
                        Content => \@Content,
                    },
                );

                if ( !$Result->{Success} ) {
                    $Errors++;

                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => "Error importing Document '$DocumentPath': " . $Result->{ErrorMessage},
                    );

                    if ($Console) {
                        $Console->Print( "<red>Error importing Document '$DocumentPath': " . $Result->{ErrorMessage} . "</red>\n" );
                    }
                }

                @Content = ();
            }
        }

        # ingest leftovers
        if (@Content) {

            my $Result = $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => $Asynchronous,
                Data         => {
                    Type    => 'docs',
                    Content => \@Content,
                },
            );

            if ( !$Result->{Success} ) {
                $Errors++;

                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => 'Error importing Documents: ' . $Result->{ErrorMessage},
                );

                if ($Console) {
                    $Console->Print( "<red>Error importing Documents: " . $Result->{ErrorMessage} . "</red>\n" );
                }
            }
        }

        if ($Errors) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Document transfer complete. ' . $Errors . ' error(s) occurred!',
            );

            if ($Console) {
                $Console->Print("<yellow>Document transfer complete. $Errors error(s) occurred!</yellow>\n");
            }
        }
        else {
            if ($Console) {
                $Console->Print("<green>Document transfer complete. Transferred $Count Document items.</green>\n");
            }
        }
    }
    return 1;
}

sub MigrateDocsAsync {
    my ( $Self, %Param ) = @_;

    # let the requester know it is run in an asynchronous context
    $Param{Asynchronous} = 1;

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "OtoboAI::Import::MigrateDocsAsync call initiated.",
    );

    my $Success = $Self->AsyncCall(
        ObjectName               => 'Kernel::System::OtoboAI::Import',
        FunctionName             => 'MigrateDocs',
        FunctionParams           => \%Param,
        Attempts                 => 1,
        MaximumParallelInstances => 0,
    );

    if ( !$Success ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Initialize async call failed!",
        );
        return;
    }

    return 1;
}

=head2 PurgeTickets()

Purges the OTOBO-AI vector DB of one or more Tickets.

returns 1 if successful or undef otherwise

    my $Success = $Object->PurgeTickets(
        TicketID => 123,    # optional, purge only this ticket
    );

=cut

sub PurgeTickets {
    my ( $Self, %Param ) = @_;

    $Self->InitImport();

    return (
        $Self->_Purge(
            Collection => 'ticket_pairs',
            SourceID   => $Param{TicketID}
        )
        && $Self->_Purge(
            Collection => 'ticket_chunks',
            SourceID   => $Param{TicketID}
        )
    );
}

=head2 PurgeFAQs()

Purges the OTOBO-AI vector DB of one or more FAQ items.

returns 1 if successful or undef otherwise

    my $Success = $Object->PurgeFAQs(
        FAQID => 123,    # optional, purge only this FAQ item
    );

=cut

sub PurgeFAQs {
    my ( $Self, %Param ) = @_;

    $Self->InitImport();

    return $Self->_Purge(
        Collection => 'faqs',
        SourceID   => $Param{FAQID},
    );
}

=head2 PurgeDocs()

Purges the OTOBO-AI vector DB of all Document items.

returns 1 if successful or undef otherwise

    my $Success = $Object->PurgeDocs();

=cut

sub PurgeDocs {
    my ( $Self, %Param ) = @_;

    $Self->InitImport();

    return $Self->_Purge( Collection => 'docs' );
}

sub _Purge {
    my ( $Self, %Param ) = @_;

    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my $Result;

    if ( $Param{SourceID} ) {

        $Result = $RequesterObject->Run(
            WebserviceID => $Self->{WebserviceID},
            Invoker      => 'DeleteByID',
            Asynchronous => 0,
            Data         => {
                type       => $Param{Collection},
                source_ids => [ $Param{SourceID} ],
            }
        );
    }
    else {

        $Result = $RequesterObject->Run(
            WebserviceID => $Self->{WebserviceID},
            Invoker      => 'Purge',
            Asynchronous => 0,
            Data         => {
                Collection => $Param{Collection}
            }
        );
    }

    return IsHashRefWithData($Result)        &&
        $Result->{Success}                   &&
        IsHashRefWithData( $Result->{Data} ) &&
        $Result->{Data}{success};
}

sub _DocumentSearch {

    my ( $Self, %Param ) = @_;

    my $DocumentRoot  = $Param{DocumentPath};
    my $NewerThanDays = $Param{NewerThanDays};
    my $Console       = $Param{Console};

    if ( !-d $DocumentRoot ) {
        if ($Console) {
            $Console->Print("<yellow>Skipping Documents (Document folder '$DocumentRoot' does not exist)...</yellow>\n");
        }
        return;
    }

    my $SecondsPerDay = 60 * 60 * 24;

    # glob files recursively starting in $DocumentRoot
    my @Files;
    find(
        {
            wanted => sub {

                # only handle files, not directories
                if ( !-d $_ ) {

                    if ($NewerThanDays) {

                        # last write time stamp
                        my ($WriteTime) = ( stat($_) )[9];

                        # if last write time is NewerThanDays
                        if ( ( time() - $WriteTime ) < ( $NewerThanDays * $SecondsPerDay ) ) {

                            # add this file to result set
                            push @Files, $_;
                        }
                    }
                    else {
                        # add this file to result set
                        push @Files, $_;
                    }
                }
            },
            no_chdir => 1
        },
        $DocumentRoot
    );

    return \@Files;
}

sub StripSignature {

    my ( $Self, %Param ) = @_;

    my $Body = $Param{Body};

    my $RegEx = $Self->{StripSignatureRegEx};
    return $Body if ( !$RegEx );

    if ( $Body =~ /$RegEx/ ) {

        return substr( $Body, 0, $-[0] );
    }
    else {

        return $Body;
    }
}

1;
