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

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Log',
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

    return unless $Param{Event} eq 'ArticleCreate';

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

    # listen to all kinds of events
    for my $IDName (qw(ArticleID TicketID)) {
        if ( !$Param{Data}{$IDName} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $IDName in Data!",
            );
            return;
        }
    }

    # get necessary objects
    my $TicketObject         = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject        = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $ArticleBackendObject = $ArticleObject->BackendForArticle(
        TicketID  => $Param{Data}{TicketID},
        ArticleID => $Param{Data}{ArticleID},
    );

    my $CacheKey = '_PopulateOTOBOAIDynamicField::AlreadyProcessed';

    # loop protection: only execute this handler once for each article
    return if ( $ArticleObject->{$CacheKey}{ $Param{Data}{ArticleID} } );

    # get dynamic field objects
    my $DynamicFieldObject        = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    my $AIFieldConfig = $DynamicFieldObject->DynamicFieldGet(
        Name => 'OTOBOAI',
    );

    # call ValueGet to trigger populating the field with AI response
    my $Success = $DynamicFieldBackendObject->ValueGet(
        DynamicFieldConfig => $AIFieldConfig,
        ObjectID           => $Param{Data}{ArticleID},
    );

    $ArticleObject->{$CacheKey}->{ $Param{Data}{ArticleID} } = 1;

    return 1;
}

1;
