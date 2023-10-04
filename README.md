# Provider
引用公开规则来自定义Surge、Clash规则

1、规则包含RuleSet、Module

2、其中RuleSet以Surge为基础，Clash规则从Surge修改而来

3、Module仅支持Surge，且会引用Script中的js文件

## RuleSet Links
因为 raw.githubusercontent.com 已被污染，所以转换成CDN链接;cdn.jsdelivr.net修改成purge.jsdelivr.net可以强制刷新CDN文件。

**Apple**

`Service`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/Service.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/Service.yaml

`Proxy`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/Proxy.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/Proxy.yaml

`Direct`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/Direct.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/Direct.yaml

`System`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/System.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/System.yaml

`iCloud`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/iCloud.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Apple/iCloud.yaml


**Proxy**

`Google`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Proxy/Google.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Proxy/Google.yaml

`Foreign`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Proxy/Foreign.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Proxy/Foreign.yaml


**Direct**

`China`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Direct/China.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Direct/China.yaml


**Extra**

`Speedtest`

- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Extra/Speedtest.list
- https://cdn.jsdelivr.net/gh/vitoegg/Provider@master/RuleSet/Extra/Speedtest.yaml


## Module Links
Module包含自定义和外部引用，为了保持及时更新不使用CDN链接。

`AdScript`

- https://raw.githubusercontent.com/vitoegg/Provider/master/Module/AdScript.sgmodule


`连接模式`

- https://raw.githubusercontent.com/vitoegg/Provider/master/Module/OutboundMode.sgmodule

`高德地图去广告`

- https://raw.githubusercontent.com/kokoryh/Script/master/Surge/module/amap.sgmodule

`小红书去广告`

- https://github.com/kokoryh/Script/blob/master/Surge/module/xiaohongshu.sgmodule




