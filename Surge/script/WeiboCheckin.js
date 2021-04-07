/*
Weibo Super Talk Check in
Made by NavePnow

[Script]
cron "0 12 * * *" script-path=checkin_surge.js
http-request https:\/\/weibo\.com\/p\/aj\/general\/button\?ajwvr=6&api=http:\/\/i\.huati\.weibo\.com\/aj\/super\/checkin max-size=0,script-path=https://raw.githubusercontent.com/NavePnow/Profiles/master/Scripts/weibo/get_cookie_surge.js

MITM = weibo.com
*/
const accounts = [
    ["戴萌", "1008087fdf9050810e3723234bd73bc5520ce3"],
    ["许佳琪", "1008088eff12bed3b5e7682f4207b03685da34"],
    ["虞书欣", "10080867e85b80401d7e932176493991acf1e7"],
    ["张语格", "10080830027b938090f8a4ebff0201e6a13bc2"],
    ["许杨玉琢", "100808db5ac566e03d1598b15cc1c555fc5450"]
    ["赵粤", "1008087ab6781e332a2ef4df88e620de9413ca"]
    ["陈琳", "100808f29ae229b39eb80a3e6395c7d167e704"]
    ["孔肖吟", "100808a714e027c1f1d9692a57a30b944f2d72"]
  
]
async function launch() {
    for (var i in accounts) {
        let name = accounts[i][0]
        let super_id = accounts[i][1]
        await weibo_super(name, super_id)
    }
    $done();
}

launch()

function weibo_super(name, super_id) {
    //$notification.post(name + "的微博超话签到", super_id, "")
    let super_url = {
        url: "https://weibo.com/p/aj/general/button?ajwvr=6&api=http://i.huati.weibo.com/aj/super/checkin&texta=%E7%AD%BE%E5%88%B0&textb=%E5%B7%B2%E7%AD%BE%E5%88%B0&status=0&id=" + super_id + "&location=page_100808_super_index&timezone=GMT+0800&lang=zh-cn&plat=MacIntel&ua=Mozilla/5.0%20(Macintosh;%20Intel%20Mac%20OS%20X%2010_15)%20AppleWebKit/605.1.15%20(KHTML,%20like%20Gecko)%20Version/13.0.4%20Safari/605.1.15&screen=375*812&__rnd=1576850070506",
        headers: {        
            Cookie: $persistentStore.read("super_cookie"),
            }
    };

    $httpClient.get(super_url, async function (error, response, data) {
        if (error) {
            $notification.post(name + "的微博超话签到错误！", "", error)
        } else {
            var obj = JSON.parse(data);
            //console.log(obj);
            var code = obj.code;
            var msg = obj.msg;
            //console.log(msg);
            if (code == 100003) {   // 行为异常，需要重新验证
                //console.log("Cookie error response: \n" + data)
                $notification.post(name + "的微博超话签到", "❕" + msg, obj.data.location)
            } else if (code == 100000) {
                tipMessage = obj.data.tipMessage;
                alert_title = obj.data.alert_title;
                alert_subtitle = obj.data.alert_subtitle;
                $notification.post(name + "的微博超话签到", "签到成功" + " 🎉", alert_title + "\n" + alert_subtitle)

            } else if (code == 382004){
                msg = msg.replace("(382004)", "")
                $notification.post(name + "的微博超话签到", "", msg + " 🎉")
            } else{
                $notification.post(name + "的微博超话签到", "", msg)
            }

        }
    })
}
