// --
// OTOBO is a web-based ticketing system for service organisations.
// --
// Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
// Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
// --
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later version.
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
// --

"use strict";

var Core = Core || {};
Core.Agent = Core.Agent || {};

/**
 * @namespace Core.Agent.OtoboAIWidget
 * @memberof Core.Agent
 * @author
 * @description
 *      This namespace contains the special module functions for the OtoboAIWidget.
 */
Core.Agent.OtoboAIWidget = (function (TargetNS) {

    /**
     * @name Init
     * @memberof Core.Agent.OtoboAIWidget
     * @function
     * @description
     *      Initializes the OtoboAIWidget module.
     */
    TargetNS.Init = function () {

        var Timer;
        var Timeout;

        function SetInitialState () {
            $('#Loader').hide();            
            $('#CancelQuestion').hide();
            $('#SubmitQuestion').show();
            clearInterval(Timer);
            clearTimeout(Timeout);
        }

        function SetRequestPendingState () {
            $('#SubmitQuestion').hide();
            $('#CancelQuestion').show();
            $('#Reply').val('');
            $('#Reply').toggleClass('OtoboAIResponseError', false);
            $('#Loader').show();
        }

        //document.getElementById("ComposeRequest").addEventListener("submit", function(event) {
        //    event.preventDefault();
        //    console.log("Form not sent");
        //});

        function StartPolling () {
            var PollingInterval = Core.Config.Get('PollingInterval');
            var TimeoutInterval = Core.Config.Get('TimeoutInterval');
            Timeout = setTimeout(function () {
                $('#Reply').toggleClass('OtoboAIResponseError', true);
                $('#Reply').val(Core.Language.Translate('Your request has timed out'));
                SetInitialState();
            }, TimeoutInterval * 1000);
            Timer = setInterval(function () {
                var Data = {
                    Action: 'OtoboAIDashboard',
                    Subaction: 'PollAIAnswer',
                    Question: $('#Request').val()
                };
                Core.AJAX.FunctionCall(Core.Config.Get('Baselink'), Data, function (Response) {
                    if (Response.Status === 'success') {
                        $('#Reply').val(Response.Value);
                        SetInitialState();
                    }
                    else if (Response.Status === 'fail') {
                        $('#Reply').toggleClass('OtoboAIResponseError', true);
                        $('#Reply').val(Core.Language.Translate('Your request has failed'));
                        SetInitialState();
                    }
                });
            }, PollingInterval * 1000);
        }

        $('#SubmitQuestion').on('click', function () {
            if (!Core.Form.Validate.ValidateElement($('#Request'))) {
                return(false);
            }
            SetRequestPendingState();
            var Data = {
                Action: 'OtoboAIDashboard',
                Subaction: 'GetAIAnswer',
                Question: $('#Request').val()
            };
            Core.AJAX.FunctionCall(Core.Config.Get('Baselink'), Data, function (Response) {
                if (Response.Status === 'success') {
                    $('#Reply').val(Response.Value);
                    SetInitialState();
                }
                else if (Response.Status === 'ongoing') {
                    $('#Reply').toggleClass('OtoboAIResponseError', true);
                    $('#Reply').val('You already have the following request going on: "' + Response.Value + '"');
                    SetInitialState();
                }
                else {
                    StartPolling();
                }
            });
            return(false);
        });

        $('#CancelQuestion').on('click', function () {
            var Data = {
                Action: 'OtoboAIDashboard',
                Subaction: 'CancelAIRequest',
            };
            Core.AJAX.FunctionCall(Core.Config.Get('Baselink'), Data, function () {});
            $('#Reply').toggleClass('OtoboAIResponseError', true);
            $('#Reply').val(Core.Language.Translate('Your request was canceled'));
            SetInitialState();
            return(false);
        });

        if ($('#Request').val()) {
            SetRequestPendingState();
            StartPolling();
        }
    };

    Core.Init.RegisterNamespace(TargetNS, 'APP_MODULE');

    return TargetNS;

}(Core.Agent.OtoboAIWidget || {}));
