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

package Kernel::GenericInterface::Operation::Ticket::UnLink;

use v5.24;
use strict;
use warnings;

use parent qw(
    Kernel::GenericInterface::Operation::Ticket::TicketUpdate
);

# core modules
use Scalar::Util qw(reftype);
use MIME::Base64 qw(encode_base64);

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(IsArrayRefWithData IsHashRefWithData IsString IsStringWithData);

our $ObjectManagerDisabled = 1;

=head1 NAME

Kernel::GenericInterface::Operation::Ticket::UnLink - Remove Link Ticket to Objects

=head1 PUBLIC INTERFACE

=head2 new()

usually, you want to create an instance of this
by using C<Kernel::GenericInterface::Operation->new();>.

=cut

sub new {
    my ( $Type, %Param ) = @_;

    my $Self = bless {}, $Type;

    # check needed objects
    for my $Needed (qw( DebuggerObject WebserviceID )) {
        if ( !$Param{$Needed} ) {
            return {
                Success      => 0,
                ErrorMessage => "Got no $Needed!",
            };
        }

        $Self->{$Needed} = $Param{$Needed};
    }

    $Self->{Config}    = $Kernel::OM->Get('Kernel::Config')->Get('GenericInterface::Operation::Link');
    $Self->{Operation} = $Param{Operation};

    return $Self;
}

=head2 Run()

perform unlink Operation removing a link from a ticket to some target.

    my $Result = $OperationObject->Run(
        Data => {
            UserLogin         => 'some agent login',                            # UserLogin or CustomerUserLogin or SessionID is
                                                                                #   required
            SessionID         => 123,

            Password  => 'some password',                                       # if UserLogin or customerUserLogin is sent then
                                                                                #   Password is required

            TicketID     => 123,                                                # TicketID or TicketNumber is required
            TicketNumber => '2004040510440485',

            TargetObject => 'FAQ',           # Ticket, ConfigItem

            TargetID     => '5',             # Id of target
            Type         => 'ParentChild',   # defailts to Normal
       },
    );

    $Result = {
        Success         => 1,                       # 0 or 1
        ErrorMessage    => '',                      # in case of error
        Data    => {
            Success   => 1,
        }
    };

=cut

sub Run {
    my ( $Self, %Param ) = @_;

    my $Result = $Self->Init(
        WebserviceID => $Self->{WebserviceID},
    );

    if ( !$Result->{Success} ) {
        $Self->ReturnError(
            ErrorCode    => 'Webservice.InvalidConfiguration',
            ErrorMessage => $Result->{ErrorMessage},
        );
    }

    # check needed stuff
    if ( !IsHashRefWithData( $Param{Data} ) ) {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.EmptyRequest',
            ErrorMessage => "TicketUnLink: The request data is invalid!",
        );
    }

    if ( !$Param{Data}->{TicketID} && !$Param{Data}->{TicketNumber} ) {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.MissingParameter',
            ErrorMessage => "TicketUnLink: TicketID or TicketNumber is required!",
        );
    }

    if ( !$Param{Data}->{TargetType} || !$Param{Data}->{TargetID} ) {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.MissingParameter',
            ErrorMessage => "TicketUnLink: TargetType and TargetID are required!",
        );
    }

    my $LinkType = $Param{Data}->{LinkType} || 'Normal';

    if (
        !$Param{Data}->{UserLogin}
        && !$Param{Data}->{SessionID}
        )
    {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.MissingParameter',
            ErrorMessage => "TicketUnLink: UserLogin or SessionID is required!",
        );
    }

    if ( $Param{Data}->{UserLogin} ) {
        if ( !$Param{Data}->{Password} ) {
            return $Self->ReturnError(
                ErrorCode    => 'TicketUnLink.MissingParameter',
                ErrorMessage => "TicketUnLink: Password or SessionID is required!",
            );
        }
    }

    # authenticate user
    my ( $UserID, $UserType ) = $Self->Auth(
        %Param,
    );

    if ( !$UserID ) {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.AuthFail',
            ErrorMessage => "TicketUnLink: User could not be authenticated!",
        );
    }

    # get ticket object
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    # check TicketID
    my $TicketID;
    if ( $Param{Data}->{TicketNumber} ) {
        $TicketID = $TicketObject->TicketIDLookup(
            TicketNumber => $Param{Data}->{TicketNumber},
            UserID       => $UserID,
        );

    }
    else {
        $TicketID = $Param{Data}->{TicketID};
    }

    if ( !($TicketID) ) {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.AccessDenied',
            ErrorMessage => "TicketUnLink: User does not have access to the ticket!",
        );
    }

    my %TicketData = $TicketObject->TicketGet(
        TicketID      => $TicketID,
        DynamicFields => 0,
        UserID        => $UserID,
    );

    if ( !IsHashRefWithData( \%TicketData ) ) {
        return $Self->ReturnError(
            ErrorCode    => 'TicketUnLink.AccessDenied',
            ErrorMessage => "TicketUnLink: User does not have access to the ticket!",
        );
    }

    # check basic needed permissions
    my $Access;
    if ( $UserType eq 'User' ) {

        $Access = $TicketObject->TicketPermission(
            Type     => 'rw',
            TicketID => $TicketID,
            UserID   => $UserID,
        );
    }
    else {
        $Access = $TicketObject->TicketCustomerPermission(
            Type     => 'rw',
            TicketID => $TicketID,
            UserID   => $UserID,
        );
    }
    if ( !$Access ) {
        return {
            ErrorCode    => 'TicketUnLink.AccessDenied',
            ErrorMessage => "TicketUnLink: Does not have permissions to update this ticket!",
        };
    }

    my $LinkObject = $Kernel::OM->Get('Kernel::System::LinkObject');

    $Access = $LinkObject->ObjectPermission(
        Object => $Param{Data}->{TargetType},
        Key    => $Param{Data}->{TargetID},
        UserID => 1,
    );
    if ( !$Access ) {
        return {
            ErrorCode    => 'TicketUnLink.AccessDenied',
            ErrorMessage => "TicketUnLink: Does not have permissions to link to this object!",
        };
    }

    $Result = $LinkObject->LinkDelete(
        Object1 => 'Ticket',
        Key1    => $TicketID,
        Object2 => $Param{Data}->{TargetType},
        Key2    => $Param{Data}->{TargetID},
        Type    => $LinkType,
        UserID  => $UserID,
    );

    return {
        Success => $Result,
        Data    => {
            Success => $Result,
        }
    };
}

1;
