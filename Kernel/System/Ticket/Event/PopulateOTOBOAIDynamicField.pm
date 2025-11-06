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

    # listen to all configured events
    if ( $Param{Config}{Event} ) {
        return unless $Param{Config}{Event} =~ /$Param{Event}/;
    }

    # check needed params in data
    for my $IDName (qw(ArticleID TicketID OldTicketData)) {
        if ( !$Param{Data}{$IDName} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $IDName in Data!",
            );
            return;
        }
    }

    # check queue restriction
    if ( IsArrayRefWithData( $Param{Config}{Queues} ) ) {
        return unless first { $_ eq $Param{Data}{OldTicketData}{Queue} } $Param{Config}{Queues}->@*;
    }

    # get necessary objects
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');

    # loop protection: only execute this handler once for each article
    my $CacheKey = '_PopulateOTOBOAIDynamicField::AlreadyProcessed';
    return if ( $ArticleObject->{$CacheKey}{ $Param{Data}{ArticleID} } );

    # prepopulate AI dynamic field with default answer
    my $OTOBOAIDFConfig = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(
        Name => 'OTOBOAI',
    );
    $Kernel::OM->Get('Kernel::System::DynamicField::Backend')->ValueSet(
        DynamicFieldConfig => $OTOBOAIDFConfig,
        ObjectID           => $Param{Data}{ArticleID},
        Value              => '<|waiting for AI answer|>',
        AsyncCall          => 1,
        UserID             => $Param{UserID},
    );

    # trigger asynchronously fetching AI answer
    $Kernel::OM->Get('Kernel::System::OtoboAI')->GetAnswerAsync(
        ObjectID => $Param{Data}{ArticleID},
    );

    $ArticleObject->{$CacheKey}{ $Param{Data}{ArticleID} } = 1;

    return 1;
}

1;
