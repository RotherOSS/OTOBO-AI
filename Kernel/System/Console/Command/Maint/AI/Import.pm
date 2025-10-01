# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
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

package Kernel::System::Console::Command::Maint::AI::Import;

use strict;
use warnings;

use Kernel::System::VariableCheck qw(:all);

use parent qw(Kernel::System::Console::BaseCommand);

## nofilter(TidyAll::Plugin::OTOBO::Perl::ForeachToFor)

# Inform the object manager about the hard dependencies.
# This module must be discarded when one of the hard dependencies has been discarded.
our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::Output::HTML::Layout',
    'Kernel::System::GenericInterface::Webservice',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::Package',
);

# Inform the CodePolicy about the soft dependencies that are intentionally not in @ObjectDependencies.
# Soft dependencies are modules that used by this object, but who don't affect the state of this object.
# There is no need to discard this module when one of the soft dependencies is discarded.
our @SoftObjectDependencies = (
    'Kernel::System::FAQ',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Import existing tickets and faq articles to the AI vector database.');
    $Self->AddOption(
        Name        => 'target',
        Description =>
            "Specify which objects will be migrated. t: Tickets; f: FAQ articles; If not specified only 't'ickets will be handled.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/^[tuci]+$/smx,
    );

    return;
}

sub PreRun {
    my ( $Self, %Param ) = @_;

    # check whether elastic search web service is enabled and if not, activate it
    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $AIWebservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {
        $Self->Print("<red>OTOBO-AI webservice not found! Unable to continue.</red>\n");
        die;
    }

    # Set the webservice id
    $Self->{WebserviceID} = $AIWebservice->{ID};

    if ( $AIWebservice->{ValidID} != 1 ) {
        $Self->Print(
            "<yellow>OTOBO-AI webservice is now activated. If you don't want to keep it enabled, please disable it manually in the admin interface, after the import is complete.</yellow>\n"
        );
        my $Success = $WebserviceObject->WebserviceUpdate(
            %{$AIWebservice},
            ValidID => 1,
            UserID  => 1,
        );

        if ( !$Success ) {
            $Self->Print("<red>OTOBO-AI webservice could not be activated! Unable to continue.</red>\n");
            die;
        }
    }

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $Targets = $Self->GetOption('target') || 't';

    if ( $Targets =~ /t/ ) {
        $Self->MigrateTickets();
    }

    if ( $Targets =~ /f/ ) {
        $Self->MigrateFAQs();
    }

    return $Self->ExitCodeOk();
}

sub MigrateTickets {
    my ( $Self, %Param ) = @_;

    my $TicketObject    = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject   = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $RequesterObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my $BatchSize = 100;
    my @TicketIDs;

    # TODO: search params via SysConfig                                    OTOBOAI::Ticket::SearchRestrictions
    if ( my $SearchRestrictions = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Ticket::SearchRestrictions') ) { 

use Data::Dumper;
print STDERR Dumper($SearchRestrictions);

        @TicketIDs = $TicketObject->TicketSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
            %{$SearchRestrictions},
        );
    } else {
print STDERR "nope\n";
        @TicketIDs = $TicketObject->TicketSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
        );
    }

return;

    # TODO: Drop existing ticket vectors (prio 2)

    my $Count     = 0;
    my $Percent10 = ( sort { $a <=> $b } ( 10, int( $#TicketIDs / 10 ) ) )[1];
    my $Percent1  = ( sort { $a <=> $b } ( 1,  int( $#TicketIDs / 100 ) ) )[1];

    if ( $#TicketIDs > 100 ) {
        $Self->Print(
            "<yellow>Tickets are transfered. This can take several hours, depending on the number of tickets.</yellow>\n"
        );
    }

    BATCH:
    while ( $Count < $#TicketIDs ) {
        my $Until = $Count + $BatchSize - 1;
        if ( $Until > $#TicketIDs ) {
            $Until = $#TicketIDs;
        }
        my @Batch = @TicketIDs[$Count .. $Until];

        my @ImportTicketsQA;
        my @ImportTicketsAgentArticles;

        TICKETID:
        for my $TicketID ( @Batch ) {

            my @Articles = $ArticleObject->ArticleList(
                TicketID => $TicketID,
            );

            next TICKETID if !@Articles;

#            # SelectionRule: channel restrictions
#            my %Channels    = map { $_->{ChannelID} => $_->{ChannelName} } ( $CommunicationChannelObject->ChannelList() );
#            return $Stop if $Articles[0]{CommunicationChannelID} ne $ChannelLookup{Email};

            my %SenderLookup = map { $_ => $ArticleObject->ArticleSenderTypeLookup( SenderType => $_ ) } qw/agent customer/;

            # SelectionRule: only consider tickets started by a customer
            next TICKETID if $Articles[0]{SenderTypeID} ne $SenderLookup{customer};

            my $QuestionArticle = shift @Articles;
            my @AnswerArticles;

            ARTICLE:
            for my $Article ( @Articles ) {
                # SelectionRule: skip tickets where the customer sent info twice without any agent interference
                next TICKETID if $Article->{SenderTypeID} eq $SenderLookup{customer} && !@AnswerArticles;

                # SelectionRule: skip articles if they are not written by an agent or are not customer visible
                next ARTICLE if $Article->{SenderTypeID} ne $SenderLookup{agent};
                next ARTICLE if $Article->{IsVisibleForCustomer} ne 1;

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

                $AnswerArticles[$i] = \%Article;
            }

            next TICKETID if !@AnswerArticles;

            push @ImportTicketsQA, [
                {
                    type => 'question',
                    text => $QuestionArticle->{Subject} . '. ' . $QuestionArticle->{Body},
                },
                {
                    type => 'answer',
                    text => $AnswerArticles[0]{Subject} . '. ' . $AnswerArticles[0]{Body},
                },
            ];

            push @ImportTicketsAgentArticles, [
                map {
                    {
                        type => 'text',
                        text => $_->{Subject} . '. ' . $_->{Body},
                    }
                } @AnswerArticles
            ];
        }

        my $Result;
        if ( @ImportTicketsQA ) {
            # Ingest Q/A articles
            $Result = $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => 0,
                Data         => {
                    Type    => 'ticket_pairs',      # currently supported: faq, documentation, ticket_pairs, ticket_chunks
                    Content => \@ImportTicketsQA,
                },
            );
        }

        if ( @ImportTicketsAgentArticles ) {
            # Ingest agent articles
            $Result = $RequesterObject->Run(
                WebserviceID => $Self->{WebserviceID},
                Invoker      => 'IngestMany',
                Asynchronous => 0,
                Data         => {
                    Type    => 'ticket_chunks',
                    Content => \@ImportTicketsAgentArticles,
                },
            );
        }

        # TODO: Could be beautified for batches
        for ( @Batch ) {
            # show progress and potentially sleep
            if ( ++$Count % $Percent10 == 0 ) {
                my $Percent = int( $Count / ( $#TicketIDs / 100 ) );
                $Self->Print(
                    "<yellow>$Count</yellow> of <yellow>$#TicketIDs</yellow> processed (<yellow>$Percent %</yellow> done).\n"
                );
            }
            elsif ( $#TicketIDs > 50 && $Count % $Percent1 == 0 ) {
                $Self->Print('. ');
                select()->flush();    # show the dot immediately
            }
        }
    }

    # TODO: Error handling
    #if ($Errors) {
    #    $Self->Print("<yellow>Ticket transfer complete. $Errors error(s) occured!</yellow>\n");
    #}
    #else {
        $Self->Print("<green>Ticket transfer complete. Transferred $Count tickets.</green>\n");
    #}

    return 1;
}

sub MigrateFAQ {
    my ( $Self, %Param ) = @_;

    # TODO: Not implemented
    $Self->Print("<yellow>not implemented.</yellow>\n");
    return;

    # check whether ITSMConfigurationManagment is installed
    my $PackageObject = $Kernel::OM->Get('Kernel::System::Package');
    my $IsInstalled   = $PackageObject->PackageIsInstalled(
        Name => 'FAQ',
    );
    if ( !$IsInstalled ) {
        $Self->Print("<yellow>Skipping FAQ articles (FAQ not installed)...</yellow>\n");

        return 1;
    }

    my $FAQObject           = $Kernel::OM->Get('Kernel::System::FAQ');
    my $GenericInterfaceObject = $Kernel::OM->Get('Kernel::GenericInterface::Requester');

    my @FAQIDs;

    # TODO: search params via SysConfig
    if ( my $SearchRestrictions = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::FAQ::SearchRestrictions') ) { 
        @FAQIDs = $FAQObject->FAQSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
            %{$SearchRestrictions},
        );
    } else {

        @FAQIDs = $FAQObject->FAQSearch(
            Result     => 'ARRAY',
            Limit      => 100_000_000,
            UserID     => 1,
            Permission => 'ro',
        );
    }

    # TODO: Drop existing ticket vectors (prio 2)

    my $Count     = 0;
    my $Percent10 = ( sort { $a <=> $b } ( 10, int( $#FAQIDs / 10 ) ) )[1];
    my $Percent1  = ( sort { $a <=> $b } ( 1,  int( $#FAQIDs / 100 ) ) )[1];

    if ( $#FAQIDs > 100 ) {
        $Self->Print(
            "<yellow>FAQ article are transfered. This can take several hours, depending on the number of faq article.</yellow>\n"
        );
    }

    my $Errors = 0;
    FAQID:
    for my $FAQID (@FAQIDs) {

        $Count++;

        # TODO: import faq article
        my $Result = Run(
            WebserviceID => $Self->{WebserviceID},
            Invoker      => 'FAQImport',
            Asynchronous => 0,
            Data         => {
                FAQID => $FAQID,
            }
        );

        # show progress and potentially sleep
        if ( $Count % $Percent10 == 0 ) {
            my $Percent = int( $Count / ( $#FAQIDs / 100 ) );
            $Self->Print(
                "<yellow>$Count</yellow> of <yellow>$#FAQIDs</yellow> processed (<yellow>$Percent %</yellow> done).\n"
            );
        }
        elsif ( $#FAQIDs > 50 && $Count % $Percent1 == 0 ) {
            $Self->Print('. ');
            select()->flush();    # show the dot immediately
        }
    }

    if ($Errors) {
        $Self->Print("<yellow>FAQ transfer complete. $Errors error(s) occured!</yellow>\n");
    }
    else {
        $Self->Print("<green>FAQ transfer complete. Transferred $Count config items.</green>\n");
    }

    return 1;
}

1;

