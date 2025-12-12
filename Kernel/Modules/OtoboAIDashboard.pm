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

package Kernel::Modules::OtoboAIDashboard;

use strict;
use warnings;

use Kernel::Language qw(Translatable);

our $ObjectManagerDisabled = 1;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $LayoutObject  = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ParamObject   = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $CacheObject   = $Kernel::OM->Get('Kernel::System::Cache');
    my $OtoboAIObject = $Kernel::OM->Get('Kernel::System::OtoboAI');
    my $MainObject    = $Kernel::OM->Get('Kernel::System::Main');

    my $Subaction        = $ParamObject->GetParam( Param => 'Subaction' ) || '';
    my $Question         = $ParamObject->GetParam( Param => 'Question' )  || '';
    my $QuestionMd5      = $MainObject->MD5sum( String => \$Question );
    my $CacheKeyQuestion = 'OtoboAI-Custom-Response-' . $QuestionMd5;
    my $CacheKeyRequest  = 'OtoboAI-Custom-Request-' . $Self->{UserID};

    my $JSON;
    if ( $Subaction eq "GetAIAnswer" ) {
        my $Answer = $CacheObject->Get(
            Type => 'OtoboAI',
            Key  => $CacheKeyQuestion,
        );
        if ($Answer) {
            $JSON = $LayoutObject->JSONEncode(
                Data => {
                    Status => 'success',
                    Value  => $Answer,
                },
            );
        }
        else
        {
            my $RequestExists = $CacheObject->Get(
                Type => 'OtoboAI',
                Key  => $CacheKeyRequest,
            );
            if ($RequestExists) {
                $JSON = $LayoutObject->JSONEncode(
                    Data => {
                        Status => 'ongoing',
                        Value  => $RequestExists,
                    },
                );
            }
            else {
                $OtoboAIObject->GetAnswerAsync(
                    Question => $Question,
                    UserID   => $Self->{UserID}
                );
                my $TTL = $Kernel::OM->Get('Kernel::Config')->Get('OtoboAIDashboard::Frontend::CacheTTL')->{Request} || 24;
                $CacheObject->Set(
                    Type  => 'OtoboAI',
                    Key   => $CacheKeyRequest,
                    Value => $Question,
                    TTL   => 60 * 60 * $TTL,
                );
                $JSON = $LayoutObject->JSONEncode(
                    Data => {
                        Status => 'pending',
                        Value  => $QuestionMd5,
                    },
                );
            }
        }
    }
    elsif ( $Subaction eq "PollAIAnswer" ) {
        my $Answer = $CacheObject->Get(
            Type => 'OtoboAI',
            Key  => $CacheKeyQuestion,
        );
        if ($Answer) {
            $JSON = $LayoutObject->JSONEncode(
                Data => {
                    Status => 'success',
                    Value  => $Answer,
                },
            );
            $CacheObject->Delete(
                Type => 'OtoboAI',
                Key  => $CacheKeyRequest,
            );
        }
        else {
            my $RequestExists = $CacheObject->Get(
                Type => 'OtoboAI',
                Key  => $CacheKeyRequest,
            );
            if ($RequestExists) {
                $JSON = $LayoutObject->JSONEncode(
                    Data => {
                        Status => 'pending',
                        Value  => $QuestionMd5,
                    },
                );
            }
            else {
                $JSON = $LayoutObject->JSONEncode(
                    Data => {
                        Status => 'fail',
                    },
                );
            }
        }
    }
    elsif ( $Subaction eq "CancelAIRequest" ) {
        $CacheObject->Delete(
            Type => 'OtoboAI',
            Key  => $CacheKeyRequest,
        );
        $JSON = $LayoutObject->JSONEncode(
            Data => {
                Status => 'canceled',
                Value  => $QuestionMd5,
            },
        );

    }

    # send JSON response
    return $LayoutObject->Attachment(
        ContentType => 'application/json; charset=' . $LayoutObject->{Charset},
        Content     => $JSON,
        Type        => 'inline',
        NoCache     => 1,
    );
}

1;
