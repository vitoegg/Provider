//event network-changed script-path=network-changed.js
//version: 2.2
//auther: tempoblink
//引用自: https://github.com/Tempoblink/Surge-Scripts/blob/master/network-changed.js

//The Notification Format.
//The Notification Format.
let TITLE = 'Outbound Changed!';
let SUBTITLE_CELLULAR = 'NetWork: ';
let SUBTITLE_WIFI = 'Wi-Fi: ';
let ABOUT_MODE = 'Outbound mode: ';
let ABOUT_IP = 'New IP address: ';

//Home ssid.

let PROXYWIFI = [
            "Tech",
            "MyWifi"
    ];

//The default outbound: 'Direct' or 'Rule' or 'Global-proxy'.
let DirectMode = "Direct";
let RuleMode = "Rule";

function changeOutboundMode(mode) {
    ABOUT_IP += $network.v4.primaryAddress;
    if($surge.setOutboundMode(mode.toLowerCase()))
        $notification.post(TITLE, NETWORK, ABOUT_MODE + mode + '\n' + ABOUT_IP);
}

//wifi select outbound
let NETWORK = "";
if ($network.v4.primaryInterface == "en0") {
    NETWORK += SUBTITLE_WIFI + $network.wifi.ssid;
    if (PROXYWIFI.indexOf($network.wifi.ssid) != -1) {
        changeOutboundMode(DirectMode);
    } else {
        changeOutboundMode(RuleMode);
    }
}else {
    NETWORK += SUBTITLE_CELLULAR + Cellular-Data;
    changeOutboundMode(RuleMode);
}

$done();
