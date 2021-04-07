/**
 * @description
 * 如果是家里WI-FI则开启直连模式
 * 如果不是家里WI-FI则开启代理模式
 */
const WIFI_DONT_NEED_PROXYS = ['Tech','MyWifi'];
if (wifiChanged()) {
  if (WIFI_DONT_NEED_PROXYS.includes($network.wifi.ssid)) {
    $surge.setOutboundMode('direct');
    $notification.post(
      'Outbound',
      `Now used Direct Mode`,
      'IP address: ${$network.v4.primaryAddress}'
    );
  } else {
    $surge.setOutboundMode('rule');
    $notification.post(
      'Outbound',
      `Now used Rule Mode`,
      'IP address: ${$network.v4.primaryAddress}'
    );
  }
}
function wifiChanged() {
  const currentWifiSSid = $persistentStore.read('current_wifi_ssid');
  const changed = currentWifiSSid !== $network.wifi.ssid;
  if (changed) {
    $persistentStore.write($network.wifi.ssid, 'current_wifi_ssid');
  }
  return changed;
}

$done();
