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

package Kernel::System::Console::Command::Maint::AI::Import;

use strict;
use warnings;

use LWP::UserAgent;
use File::Basename        qw(basename dirname);
use HTTP::Request::Common qw{ POST };

use Kernel::System::VariableCheck qw(:all);

use parent qw(Kernel::System::Console::BaseCommand);

## nofilter(TidyAll::Plugin::OTOBO::Perl::ForeachToFor)

our @ObjectDependencies = (
    'Kernel::System::OtoboAI::Import',
);

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Import existing tickets and faq articles to the AI vector database.');
    $Self->AddOption(
        Name        => 'target',
        Description =>
            "Specify which objects will be migrated. t: Tickets; f: FAQ articles; d: documents. If not specified all sources will be handled.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/^[tfd]+$/smx,
    );
    $Self->AddOption(
        Name        => 'reimport',
        Description =>
            "Do a re-import, which means the AI vectorstore and fulltext postgres DBs will be purged for the target collections.",
        Required => 0,
        HasValue => 0,
    );
    $Self->AddOption(
        Name        => 'purge',
        Description =>
            "purge target collections).",
        Required => 0,
        HasValue => 0,
    );
    $Self->AddOption(
        Name        => 'sample-nth',
        Description =>
            "Only relevant with --do-scoring, specifies the sample size. Take every nth num for sampling. Specifying 10 will take every tenth, resulting in a 10% sample size. Specify 5 to take every 5th which will give 20% Sampelsize. Specify 20 to take every 20th which will yield 5% sample size. The default is 10.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/[0-9]+/smx,
    );
    $Self->AddOption(
        Name        => 'sample',
        Description =>
            "Specify a file path to write a sample.json file containing TicketIDs to sample. When specified, then severy sample-nth Ticket will not be imported, but added to the list of sample ids. The default for sample-nth is 10 to sample every 10th Ticket (10% sample size). Override with the --sample-nth parameter.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'reference',
        Description =>
            "Specify a file path to an existing sample.json file containing TicketIDs to reference. When specified, no new sample will be generated, but all TicketIDs from the reference sample file will be hold back again for scoring.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'use-case',
        Description =>
            "The use-case name(s) to ingest data for. If left empty, all use cases will be ingested.",
        Required   => 0,
        HasValue   => 1,
        ValueRegex => qr/.*/smx,
        Multiple   => 1,
    );

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $Sample    = $Self->GetOption('sample');
    my $Reference = $Self->GetOption('reference');
    my $SampleNth = $Self->GetOption('sample-nth') || 10;

    my $ReImport = $Self->GetOption('reimport');
    my $Purge    = $Self->GetOption('purge');
    my $UseCases = $Self->GetOption('use-case');

    my $Targets = $Self->GetOption('target') || "tdf";

    my $ImportObject = $Kernel::OM->Get('Kernel::System::OtoboAI::Import');

    if ( $Targets =~ /t/ ) {

        if ( $ReImport || $Purge ) {
            $ImportObject->PurgeTickets();
        }

        if ( !$Purge ) {
            $ImportObject->MigrateTickets(
                Sample    => $Sample,
                SampleNth => $SampleNth,
                Reference => $Reference,
                UseCases  => $UseCases,
                Console   => $Self,
            );
        }
    }

    if ( $Targets =~ /f/ ) {

        if ( $ReImport || $Purge ) {
            $ImportObject->PurgeFAQs();
        }

        if ( !$Purge ) {
            $ImportObject->MigrateFAQs(
                UseCases => $UseCases,
                Console  => $Self,
            );
        }
    }

    if ( $Targets =~ /d/ ) {

        if ( $ReImport || $Purge ) {
            $ImportObject->PurgeDocs();
        }

        if ( !$Purge ) {
            $ImportObject->MigrateDocs(
                UseCases => $UseCases,
                Console  => $Self,
            );
        }
    }

    return $Self->ExitCodeOk();
}

1;
