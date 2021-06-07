var body = $response.body;
var url = $request.url;

const path1 = "/home/api/ad/v1/bootAd";
const path2 = "/home/api/ad/v1/popupAd";
if (url.indexOf(path1) != -1){
  let obj = JSON.parse(body);
    obj["content"]["adExist"] = false;
    obj["content"]["zipUrl"] = "https://source.48.cn";
    body=JSON.stringify(obj);
 };
   
if (url.indexOf(path2) != -1){
  let obj = JSON.parse(body);
     obj["content"]["show"] = false;          
     obj["content"]["lastUpdateTime"] = 4084432629000;
     body=JSON.stringify(obj);
};
   
 $done({body});
