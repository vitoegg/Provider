//event network-changed script-path=network-changed.js
//version: 2.2
//auther: tempoblink
//引用自: https://github.com/Tempoblink/Surge-Scripts/blob/master/network-changed.js

//The Notification Format.
let TITLE = 'Outbound Changed!';
let ABOUT_MODE = 'Outbound mode: ';
let ABOUT_IP = 'New IP address: ';

//black ssid.

let BLOCKLIST = [
            "Tech",
            "MyWifi"
    ];

//The default outbound: 'Direct' or 'Rule' or 'Global-proxy'.
let BlockList = "Direct";
let Others = "Rule";

function changeOutboundMode(mode) {
    ABOUT_IP += $network.v4.primaryAddress;
    if($surge.setOutboundMode(mode.toLowerCase()))
        $notification.post(TITLE, NETWORK, ABOUT_MODE + mode + '\n' + ABOUT_IP);
}

//wifi select outbound
if ($network.v4.primaryInterface == "en0") {
    if (BLOCKLIST.indexOf($network.wifi.ssid) != -1) {
        changeOutboundMode(BlockList);
    } else {
        changeOutboundMode(Others);
    }
}else {
    changeOutboundMode(Others);
}

$done();
