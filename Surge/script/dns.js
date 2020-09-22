if ($network.wifi.ssid === 'Tech' || $network.wifi.ssid === 'MyWifi') {
$done({servers:$network.dns})
} else {
$done({})
}