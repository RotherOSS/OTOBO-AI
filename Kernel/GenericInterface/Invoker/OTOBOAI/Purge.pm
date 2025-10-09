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

package Kernel::GenericInterface::Invoker::OTOBOAI::Purge;

use v5.24;
use strict;
use warnings;

# core modules
use MIME::Base64 qw(encode_base64);

# CPAN modules
use URI::Escape qw(uri_unescape);

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);

our $ObjectManagerDisabled = 1;

=for stopwords postgres ai fulltext

=head1 NAME

Kernel::GenericInterface::Invoker::OTOBOAI::Purge

=head1 PUBLIC INTERFACE

=head2 new()

usually, you want to create an instance of this
by using Kernel::GenericInterface::Invoker->new();

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = bless {}, $Type;

    # check needed params and store them in $Self
    for my $Needed (qw/DebuggerObject WebserviceID/) {
        if ( !$Param{$Needed} ) {
            return {
                Success      => 0,
                ErrorMessage => "Need $Needed!"
            };
        }

        $Self->{$Needed} = $Param{$Needed};
    }

    return $Self;
}

=head2 PrepareRequest()

prepare the invocation of the configured remote web service. This will
call the Purge endpoint on the otobo-ai-docker container to
reset the otobo AI vector db and the fulltext postgres db.
Call this before doing a re-import so you can start over from scratch.

    my $Result = $InvokerObject->PrepareRequest(
        Data => {}                               # data payload
    );

    $Result = {
        Success         => 1,                   # 0 or 1
        ErrorMessage    => '',                  # in case of error
        Data            => {}                    # data payload after Invoker
    };

=cut

sub PrepareRequest {
    my ( $Self, %Param ) = @_;

    return {
        Success => 1,
        Data    => {},
    };
}

=head2 HandleResponse()

handle response data of the configured remote web service.
This will just return the data that was passed to the function.

    my $Result = $InvokerObject->HandleResponse(
        ResponseSuccess      => 1,              # success status of the remote web service
        ResponseErrorMessage => '',             # in case of web service error
        Data => {                               # data payload
            ...
        },
    );

    $Result = {
        Success         => 1,                   # 0 or 1
        ErrorMessage    => '',                  # in case of error
        Data            => {                    # data payload after Invoker
            success => 'true'
        },
    };

=cut

sub HandleResponse {
    my ( $Self, %Param ) = @_;

    # if there was an error in the response, forward it
    if ( !$Param{ResponseSuccess} ) {
        return {
            Success      => 0,
            ErrorMessage => $Param{ResponseErrorMessage},
        };
    }

    return {
        Success => 1,
        Data    => $Param{Data},
    };
}

1;
