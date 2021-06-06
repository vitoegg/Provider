const scriptName = "Pocket48";
const storyAidKey = "Pocket48_aid";
const blackKey = "Pocket48_black";
let magicJS = MagicJS(scriptName, "INFO");

//Customize blacklist
let blacklist = [];
if (magicJS.read(blackKey)) {
  blacklist = magicJS.read(blackKey).split(";");
} else {
  const defaultList = "";
  magicJS.write(blackKey, defaultList);
  blacklist = defaultList.split(";");
}

(() => {
  let body = null;
  if (magicJS.isResponse) {
    switch (true) {
      // 开屏广告处理
      case /^https?:\/\/pocketapi\.48\.cn\/home\/api\/ad\/v1\/bootAd/.test(magicJS.request.url):
        try {
          let obj = JSON.parse(magicJS.response.body);
          obj["content"]["adExist"] = false;
          obj["content"]["zipUrl"] = "https://source.48.cn/20210527/1622011896626.zip";
          }
          body = JSON.stringify(obj);
        } catch (err) {
          magicJS.logError(`开屏广告处理异常：${err}`);
        }
        break;

      // 直播去广告^https?:\/\/pocketapi\.48\.cn\/home\/api\/ad\/v1\/popupAd/
      case /^https?:\/\/pocketapi\.48\.cn\/home\/api\/ad\/v1\/popupAd/.test(magicJS.request.url):
        try {
          let obj = JSON.parse(magicJS.response.body);
          obj["content"]["show"] = false;          
          obj["content"]["lastUpdateTime"] = 4084432629000;
          body = JSON.stringify(obj);
        } catch (err) {
          magicJS.logError(`开屏气泡处理异常：${err}`);
        }
        break;

      default:
        magicJS.logWarning("触发意外的请求处理，请确认脚本或复写配置正常。");
        break;
    }
  } else {
    magicJS.logWarning("触发意外的请求处理，请确认脚本或复写配置正常。");
  }
  if (body) {
    magicJS.done({ body });
  } else {
    magicJS.done();
  }
})();
