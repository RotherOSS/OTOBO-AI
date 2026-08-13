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

package Kernel::System::Ticket::Event::PopulateOTOBOAIDynamicField;

use strict;
use warnings;

# core modules
use List::Util qw(first);

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Log',
    'Kernel::System::OtoboAI',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::GenericInterface::Webservice',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(Data Event Config UserID)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    # check needed param in data
    for my $IDName (qw(TicketID)) {
        if ( !$Param{Data}{$IDName} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $IDName in Data!",
            );
            return;
        }
    }

    my $WebserviceObject = $Kernel::OM->Get('Kernel::System::GenericInterface::Webservice');

    my $AIWebservice = $WebserviceObject->WebserviceGet(
        Name => 'OTOBO-AI',
    );

    if ( !$AIWebservice ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "OTOBO-AI webservice not found!",
        );
        return;
    }

    if ( $AIWebservice->{ValidID} != 1 ) {

        return;
    }

    if ( $Param{Event} eq 'TicketQueueUpdate' ) {
        $Self->_PurgeAIDynamicFields( TicketID => $Param{Data}{TicketID} );
    }

    # get necessary objects
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $ConfigObject  = $Kernel::OM->Get('Kernel::Config');

    # handle missing article data by fetching last customer article
    my $ArticleID;
    if ( $Param{Data}{ArticleID} ) {
        $ArticleID = $Param{Data}{ArticleID};
    }
    else {
        my @Articles = $ArticleObject->ArticleList(
            TicketID   => $Param{Data}{TicketID},
            SenderType => 'customer',
            OnlyLast   => 1,
        );
        if (@Articles) {
            $ArticleID = $Articles[0]{ArticleID};
        }
    }

    if ( !$ArticleID ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "No ArticleID in Data and found no customer article!",
        );
        return;
    }

    my %TicketNew = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
        TicketID => $Param{Data}{TicketID},
        UserID   => $Param{UserID},
    );

    # check queue restriction
    if ( IsArrayRefWithData( $Param{Config}{Queues} ) ) {
        return unless first { $_ eq $TicketNew{Queue} } $Param{Config}{Queues}->@*;
    }

    # check sendertype - only auto-populate customer articles
    my %SenderLookup = map {
        $_ => $ArticleObject->ArticleSenderTypeLookup( SenderType => $_ )
    } qw/agent customer system/;

    my $ArticleBackendObject = $ArticleObject->BackendForArticle(
        TicketID  => $Param{Data}{TicketID},
        ArticleID => $ArticleID,
    );

    my %Article = $ArticleBackendObject->ArticleGet(
        TicketID  => $Param{Data}{TicketID},
        ArticleID => $ArticleID,
    );

    return if ( $Article{SenderTypeID} != $SenderLookup{'customer'} );

    # loop protection: only execute this handler once for each article
    my $CacheKey = '_PopulateOTOBOAIDynamicField::AlreadyProcessed';
    return if ( $ArticleObject->{$CacheKey}{$ArticleID} );

    # prepopulate AI dynamic field with default answer
    my $DynamicFieldName = $ConfigObject->Get('OTOBOAI::DynamicFieldOTOBOAI') || 'OTOBOAI';
    my $OTOBOAIDFConfig  = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(
        Name => $DynamicFieldName,
    );
    if ( !IsHashRefWithData($OTOBOAIDFConfig) ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "DynamicField '$DynamicFieldName' not found on the system!",
        );
        return;
    }

    # if a value exists, abort
    #   value either being the placeholder or an actual value
    #   in both cases we do not want to trigger a new request
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');
    my $CurrentValue              = '';
    my $OverwriteFlag             = $ConfigObject->Get('OTOBOAI::OverwritePreviousResponse') || 0;
    if ( !$OverwriteFlag ) {
        $CurrentValue = $DynamicFieldBackendObject->ValueGet(
            DynamicFieldConfig => $OTOBOAIDFConfig,
            ObjectID           => $ArticleID,
            UserID             => $Param{UserID},
        );
    }

    return if $CurrentValue;

    my $Placeholder = $Kernel::OM->Get('Kernel::Config')->Get('OTOBOAI::Placeholder') || '<|waiting for AI answer|>';
    $Kernel::OM->Get('Kernel::System::DynamicField::Backend')->ValueSet(
        DynamicFieldConfig => $OTOBOAIDFConfig,
        ObjectID           => $ArticleID,
        Value              => $Placeholder,
        DoWrite            => 1,
        UserID             => $Param{UserID},
    );

    # restrict population to RAG mapping setting
    my $QueueToRAGMapping = $ConfigObject->Get('OTOBOAI::QueueToRAGMapping');
    return if ( $QueueToRAGMapping && !$QueueToRAGMapping->{ $TicketNew{Queue} } );

    # trigger asynchronously fetching AI answer
    $Kernel::OM->Get('Kernel::System::OtoboAI')->GetAnswerAsync(
        ObjectID => $ArticleID,
    );

    $ArticleObject->{$CacheKey}{$ArticleID} = 1;

    return 1;
}

sub _PurgeAIDynamicFields {

    my ( $Self, %Param ) = @_;

    my $ArticleObject             = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $ConfigObject              = $Kernel::OM->Get('Kernel::Config');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    my @Articles = $ArticleObject->ArticleList(
        TicketID => $Param{TicketID},
    );

    my $DynamicFieldName = $ConfigObject->Get('OTOBOAI::DynamicFieldOTOBOAI') || 'OTOBOAI';
    my $OTOBOAIDFConfig  = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(
        Name => $DynamicFieldName,
    );

    for my $Article (@Articles) {

        my $Success = $DynamicFieldBackendObject->ValueSet(
            DynamicFieldConfig => $OTOBOAIDFConfig,
            ObjectID           => $Article->{ArticleID},
            Value              => undef,
            DoWrite            => 1,
            UserID             => 1,
        );

        if ( !$Success ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Failed to clear OTOBO AI DynamicField for Article $Article->{ArticleID}.",
            );
        }
        else {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'debug',
                Message  => "Cleared OTOBO AI DynamicField for Article $Article->{ArticleID}.",
            );
        }
    }

    return;
}

1;
