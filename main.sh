#!/bin/bash
_sys_judg()
{
sysa=`cat /etc/issue`
sysb="Ubuntu"
sysc=`getconf LONG_BIT`
# local timeout=2
# local target=www.google.com
# local ret_code=`curl -I -s --connect-timeout ${timeout} ${target} -w %{http_code} | tail -n1`
if [[ "$UID" = 0 ]];then
    clear
    echo
    echo -e "\033[31m警告：请在非root用户下运行该脚本……\033[0m"
    echo
    exit
elif [[ ( $sysa != *$sysb* ) || ( $sysc != 64 ) ]]; then
	clear
    echo
    echo -e "\033[31m警告：请在Ubuntu18+ x64系统下运行该脚本……\033[0m"
    echo
    exit
fi
#检查网络状态
# if [ "x$ret_code" != "x200" ]; then
	# clear
	# echo
	# echo -e "\033[31m警告：您网络不能科学上网，请检查网络后重试…\033[0m"
	# echo
	# exit
# fi
# 判断是否安装了sudo
if ! type sudo >/dev/null 2>&1; then
    clear
    echo
    echo -e "\033[31m警告：您未安装sudo，请切换至root用户下安装(apt-get install sduo)…\033[0m"
    echo
    exit
fi
# 判断是否成功安装了wget
if ! type wget >/dev/null 2>&1; then
	echo
    echo -e "\033[35m警告：您的系统未安装wget，正在给您安装，请稍后…\033[0m"
	echo
	sudo apt-get install wget -y >/dev/null 2>&1
	sleep 0.1
	if ! type wget >/dev/null 2>&1; then
		clear
		echo
		echo -e "\033[31m警告：安装wget失败，请检查网络重试…\033[0m"
		echo
		exit
	fi
fi
}
path=$(dirname $(readlink -f $0))
cd ${path}
##################################################
menub()
{
clear
echo -e `date`
cat <<EOF
-----------------------------------
>>>菜单主页:
`echo -e "\033[35m 1)首次运行固件更新编译脚本\033[0m"`
`echo -e "\033[35m 2)主菜单\033[0m"`
`echo -e "\033[35m Q)退出\033[0m"`
EOF
read -n 1 -p  "请输入对应序列号：" num1
case $num1 in
	1)
    echo -e "\033[32m >>>首次运行固件更新编译脚本-> \033[0m"
	if [[ ( ! -d ${path}/lede ) ||  ( ! -d ${path}/openwrt ) ]]; then
		clear
		echo
		echo "本地没源码，正在准备拉去源码…"
		echo
		_lede_code
	else
		clear
		echo
		echo -e "\033[31m警告：本地也有开发或稳定源码，无需更新…\033[0m"
		echo
		read -n 1 -p  "请回车继续…"
		echo
		menu
	fi
    ;;
    2)
    echo -e "\033[32m >>>返回主菜单-> \033[0m"
    menu
    ;;
    Q|q)
    echo -e "\n\033[32m--------退出--------- \033[0m"
    exit 0
    ;;
    *)
    echo -e "\033[31m err：请输入正确的编号\033[0m"
    read -n 1 -p  "请回车继续…"
	menub
esac
}

menu()
{
clear
echo -e `date`
cat <<EOF

Openwrt Firmware One-click Update Compilation Script

Script By Lenyu	Version v2.4.2

-----------------------------------
>>>菜单主页:
`echo -e "\033[35m 1)开发版-固件编译\033[0m"`
`echo -e "\033[35m 2)稳定版-固件编译\033[0m"`
`echo -e "\033[35m 3)主菜单\033[0m"`
`echo -e "\033[35m Q)退出\033[0m"`
EOF
read -n 1 -p  "请输入对应序列号：" num1
case $num1 in
    1)
    echo -e "\033[32m >>>开发版-固件编译-> \033[0m"
	_dev_update
    ;;
    2)
    echo -e "\033[32m >>>稳定版-固件编译-> \033[0m"
    _sta_update
    ;;
    3)
    echo -e "\033[32m >>>返回主菜单-> \033[0m"
    menu
    ;;
    Q|q)
    echo -e "\n\033[32m--------退出--------- \033[0m"
    exit 0
    ;;
    *)
    echo -e "\033[31m err：请输入正确的编号\033[0m"
    read -n 1 -p  "请回车继续…"
	menu
esac
}

_dev_update()
{
cat <<EOF
-----------------------------------
>>>菜单主页:
`echo -e "\033[35m 1)开发版-检查更新并编译固件\033[0m"`
`echo -e "\033[35m 2)开发版-强制更新固件\033[0m"`
`echo -e "\033[35m 3)主菜单\033[0m"`
`echo -e "\033[35m Q)退出\033[0m"`
EOF
read -n 1 -p  "请输入对应序列号：" num1
case $num1 in
	1)
    echo -e "\033[32m >>>开发版-检查更新并编译固件-> \033[0m"
	dev_noforce_update
    ;;
    2)
    echo -e "\033[32m >>>开发版-强制更新固件-> \033[0m"
	dev_force_update
    ;;
    3)
    echo -e "\033[32m >>>主菜单-> \033[0m"
    menu
    ;;
    Q|q)
    echo -e "\n\033[32m--------退出--------- \033[0m"
    exit 0
    ;;
    *)
    echo -e "\033[31m err：请输入正确的编号\033[0m"
    read -n 1 -p  "请回车继续…"
	_dev_update
esac
}

_sta_update()
{
cat <<EOF
-----------------------------------
>>>菜单主页:
`echo -e "\033[35m 1)稳定版-检查更新并编译固件\033[0m"`
`echo -e "\033[35m 2)稳定版-强制更新固件\033[0m"`
`echo -e "\033[35m 3)主菜单\033[0m"`
`echo -e "\033[35m Q)退出\033[0m"`
EOF
read -n 1 -p  "请输入对应序列号：" num1
case $num1 in
	1)
    echo -e "\033[32m >>>稳定版-检查更新并编译固件-> \033[0m"
	sta_noforce_update
    ;;
    2)
    echo -e "\033[32m >>>稳定版-强制更新固件-> \033[0m"
	sta_force_update
    ;;
    3)
    echo -e "\033[32m >>>主菜单-> \033[0m"
   menu
    ;;
    Q|q)
    echo -e "\n\033[32m--------退出--------- \033[0m"
    exit 0
    ;;
    *)
    echo -e "\033[31m err：请输入正确的编号\033[0m"
    read -n 1 -p  "请回车继续…"
	_sta_update
esac
}

_dev_dl_downlaond()
{
clear
echo -e `date`
cat <<EOF
-----------------------------------
`echo -e "\033[35m 由于您是首次下载源码编译，作者热心给您准备好源码所需dl文件，您是选择下载?"`
EOF
read -n 1 -p  " 选择下载输入(Y/N)：" num1
case $num1 in
	Y|y)
    echo -e "\033[32m >>>正在从谷歌网盘拉取dl文件，请稍后…-> \033[0m"
	echo
	if [ ! -d ${path}/wget ]; then
		mkdir -p ${path}/wget
	fi
	if [ ! -d  "xray_update" ]; then
	mkdir -p ${path}/xray_update
	fi
	wget -P ${path}/wget/ 'https://git.io/Jt4cj' -O ${path}/wget/gdlink
	bash ${path}/wget/gdlink 'https://drive.google.com/u/0/uc?id=1BJTkJgwinKL67i0gb_tG2p3OE-Hv_4uA&export=download' |xargs -n1 wget -c -O ${path}/xray_update/dev_dl.tar.gz
	#####文件MD5校验########
	wget -P ${path}/xray_update https://raw.githubusercontent.com/Lenyu2020/openwrt-update-script/main/file/dev_dl.tar.gz.md5 -O  ${path}/xray_update/dev_dl.tar.gz.md5 >/dev/null 2>&1
	cd ${path}/xray_update && md5sum -c --status ${path}/xray_update/dev_dl.tar.gz.md5
	if [ $? != 0 ]; then
		echo "您下载dl文件失败，请检查网络重试/回车后选择N跳过…"
		read -n 1 -p  "请回车，回到子菜单操作…"
		_dev_dl_downlaond
	fi
	cd ${path}
	########
	tar -zxvf ${path}/xray_update/dev_dl.tar.gz && mv -f ${path}/xray_update/dev_dl/* ${path}/lede/dl >/dev/null 2>&1
	rm -rf ${path}/wget/gdlink
	rm -rf ${path}/xray_update/dev_dl.tar.gz*
	echo
	echo -e "\033[32m >>>开发版-源码初始化完成…-> \033[0m"
	echo
	read -n 1 -p  "请回车，返回主菜单操作…"
	echo
	menu
    ;;
    n|N)
	echo
	echo -e "\033[32m >>>开发版-源码初始化完成…-> \033[0m"
	echo
	read -n 1 -p  "请回车，返回主菜单操作…"
	echo
	rm -rf ${path}/wget/gdlink
	menu
	;;
    *)
    echo -e "\033[31m err：只能选择Y/N\033[0m"
    read -n 1 -p  "请回车继续…"
	_dev_dl_downlaond
esac
}

_sta_dl_downlaond()
{
clear
echo -e `date`
cat <<EOF
-----------------------------------
`echo -e "\033[35m 由于您是首次下载源码编译，作者热心给您准备好源码所需dl文件，您是选择下载?"`
EOF
read -n 1 -p  " 选择下载输入(Y/N)：" num1
case $num1 in
	Y|y)
     echo -e "\033[32m >>>正在从谷歌网盘拉取dl文件，请稍后…-> \033[0m"
	echo
	if [ ! -d ${path}/wget ]; then
		mkdir -p ${path}/wget
	fi
	if [ ! -d  "xray_update" ]; then
	mkdir -p ${path}/xray_update
	fi
	wget -P ${path}/wget/ 'https://git.io/Jt4cj' -O ${path}/wget/gdlink
	bash ${path}/wget/gdlink 'https://drive.google.com/u/0/uc?id=1QsoMiy4s0ovNLcbETSaYWEpM_0YYP0rA&export=download' |xargs -n1 wget -c -O ${path}/xray_update/sta_dl.tar.gz
	#####文件MD5校验########
	wget -P ${path}/xray_update https://raw.githubusercontent.com/Lenyu2020/openwrt-update-script/main/file/sta_dl.tar.gz.md5 -O  ${path}/xray_update/sta_dl.tar.gz.md5 >/dev/null 2>&1
	cd ${path}/xray_update && md5sum -c --status ${path}/xray_update/sta_dl.tar.gz.md5
	if [ $? != 0 ]; then
		echo "您下载dl文件失败，请检查网络重试/回车后选择N跳过…"
		read -n 1 -p  "请回车，回到子菜单操作…"
		_sta_dl_downlaond
	fi
	cd ${path}
	########
	tar -zxvf ${path}/xray_update/sta_dl.tar.gz && mv -f ${path}/xray_update/sta_dl/* ${path}/openwrt/dl >/dev/null 2>&1
	rm -rf ${path}/wget/gdlink
	rm -rf ${path}/xray_update/sta_dl.tar.gz*
	echo
	echo -e "\033[32m >>>稳定版-源码初始化完成…-> \033[0m"
	echo
	read -n 1 -p  "请回车，返回主菜单操作…"
	echo
	menu
    ;;
    n|N)
	echo
	echo -e "\033[32m >>>稳定版-源码初始化完成…-> \033[0m"
	echo
	read -n 1 -p  "请回车，返回主菜单操作…"
	echo
	rm -rf ${path}/wget/gdlink
	menu
    ;;
    *)
    echo -e "\033[31m err：只能选择Y/N\033[0m"
    read -n 1 -p  "请回车继续…"
	_sta_dl_downlaond
esac
}


_lede_code()
{
cat <<EOF
-----------------------------------
>>>请选择要拉去的源码版本分支:
`echo -e "\033[35m 1)lean大雕开发版源码\033[0m"`
`echo -e "\033[35m 2)lean大雕稳定版源码\033[0m"`
EOF
read -n 1 -p  "请输入对应序列号：" num2
case $num2 in
    1)
    echo -e "\033[32m >>>正在拉去开发版源码，请稍后…-> \033[0m"
    sudo apt-get update -y  && sudo apt-get -y install build-essential asciidoc binutils bzip2 gawk gettext git libncurses5-dev libz-dev patch python3 python2.7 unzip zlib1g-dev lib32gcc1 libc6-dev-i386 subversion flex uglifyjs git-core gcc-multilib p7zip p7zip-full msmtp libssl-dev texinfo libglib2.0-dev xmlto qemu-utils upx libelf-dev autoconf automake libtool autopoint device-tree-compiler g++-multilib antlr3 gperf wget curl swig rsync
	git clone https://github.com/coolsnowwolf/lede.git ${path}/lede
	empty_dir=` ls ${path}/lede -A $1|wc -w`
	if [[ "$empty_dir"  = 0 ]]; then
		echo "源码拉去失败，请检查网络…"
		_lede_code
	else
		cd ${path}/lede
		sed -i 's/#src-git helloworld/src-git helloworld/g'  ${path}/lede/feeds.conf.default
		sed -i '$a src-git passwall https://github.com/xiaorouji/openwrt-passwall' ${path}/lede/feeds.conf.default
	fi
	#拉去第三方的code
	git clone https://github.com/vernesong/OpenClash.git ${path}/lede/package/luci-app-openclash
	cd ${path}/lede/package/luci-app-openclash
	git init
	git remote add -f origin https://github.com/vernesong/OpenClash.git
	git config core.sparsecheckout true
	echo "luci-app-openclash" >> .git/info/sparse-checkout
	git pull origin master
	git branch --set-upstream-to=origin/master master
	cd ${path}/lede
	#主题
	rm -rf ${path}/lede/package/lean/luci-theme-argon
	git clone -b 18.06 https://github.com/jerrykuku/luci-theme-argon.git  ${path}/lede/package/lean/luci-theme-argon
	wget -P ${path}/wget https://raw.githubusercontent.com/Lenyu2020/openwrt_update/main/file/dev_diff -O  ${path}/wget/dev_diff >/dev/null 2>&1
	sleep 0.3
	mv ${path}/wget/dev_diff ${path}/lede/.config
	echo
	_dev_dl_downlaond
    ;;
    2)
    echo -e "\033[32m >>>正在拉去稳定版源码，请稍后…-> \033[0m"
	sudo apt-get update -y  && sudo apt-get -y install build-essential asciidoc binutils bzip2 gawk gettext git libncurses5-dev libz-dev patch python3 python2.7 unzip zlib1g-dev lib32gcc1 libc6-dev-i386 subversion flex uglifyjs git-core gcc-multilib p7zip p7zip-full msmtp libssl-dev texinfo libglib2.0-dev xmlto qemu-utils upx libelf-dev autoconf automake libtool autopoint device-tree-compiler g++-multilib antlr3 gperf wget curl swig rsync
	git clone https://github.com/coolsnowwolf/openwrt.git ${path}/openwrt
	empty_dir=` ls ${path}/openwrt -A $1|wc -w`
	if [[ "$empty_dir"  = 0 ]]; then
		echo "源码拉去失败，请检查网络…"
		_lede_code
	else
		cd ${path}/openwrt
		sed -i 's/#src-git helloworld/src-git helloworld/g'  ${path}/openwrt/feeds.conf.default
		sed -i '$a src-git passwall https://github.com/xiaorouji/openwrt-passwall' ${path}/openwrt/feeds.conf.default
	fi
	#拉去第三方的code
	# git clone https://github.com/vernesong/OpenClash.git ${path}/openwrt/package/luci-app-openclash
	# cd ${path}/openwrt/package/luci-app-openclash
	# git init
	# git remote add -f origin https://github.com/vernesong/OpenClash.git
	# git config core.sparsecheckout true
	# echo "luci-app-openclash" >> .git/info/sparse-checkout
	# git pull origin master
	# git branch --set-upstream-to=origin/master master
	# cd ${path}/openwrt
	#主题
	rm -rf ${path}/openwrt/package/lean/luci-theme-argon
	git clone -b 18.06 https://github.com/jerrykuku/luci-theme-argon.git  ${path}/openwrt/package/lean/luci-theme-argon

	wget -P ${path}/wget https://raw.githubusercontent.com/Lenyu2020/openwrt_update/main/file/sta_diff -O  ${path}/wget/sta_diff >/dev/null 2>&1
	sleep 0.3
	mv ${path}/wget/sta_diff ${path}/openwrt/.config
	echo
	_sta_dl_downlaond
	;;
    *)
    echo -e "\033[31m err：请输入正确的编号\033[0m"
    read -n 1 -p  "请回车继续…"
	clear
	_lede_code
	echo
esac
}


dev_force_update()
{
if [[  ! -d ${path}/lede  ]]; then
	clear
	echo
	echo -e "\033[31m警告：本地还没源码，请选脚本第1项目初始化…\033[0m"
	echo
	read -n 1 -p  "请回车继续…"
	echo
	menub
fi
cd ${path}
clear
echo
echo "脚本正在运行中…"
##lede
#由于源码xray位置改变，需要加入一个判断清除必要的文件
if [ ! -d  "${path}/lede/feeds/helloworld/xray-core" ]; then
	sed -i 's/#src-git helloworld/src-git helloworld/'  ${path}/lede/feeds.conf.default
	rm -rf ${path}/lede/package/lean/xray
	rm -rf ${path}/lede/tmp
fi
#清理
rm -rf ${path}/lede/rename.sh
rm -rf ${path}/lede/package/lean/default-settings/files/zzz-default-settings
rm -rf ${path}/lede/feeds/helloworld/xray-core/Makefile
echo
git -C ${path}/lede pull >/dev/null 2>&1
git -C ${path}/lede rev-parse HEAD > new_lede
echo
wget -P ${path}/lede/package/lean/default-settings/files https://raw.githubusercontent.com/coolsnowwolf/lede/master/package/lean/default-settings/files/zzz-default-settings -O  ${path}/lede/package/lean/default-settings/files/zzz-default-settings >/dev/null 2>&1
echo
#####网络配置######
if [[ ! -d "${path}/lede/files/etc/config" ]]; then
	sed -i 's/192.168.10.1/192.168.1.1/g' ${path}/lede/package/base-files/files/bin/config_generate
	mkdir -p ${path}/lede/files/etc/config
	cat>${path}/lede/files/etc/config/network<<-EOF
	config interface 'loopback'
		option ifname 'lo'
		option proto 'static'
		option ipaddr '127.0.0.1'
		option netmask '255.0.0.0'

	config globals 'globals'
		option ula_prefix 'fd3f:2c76:9c66::/48'

	config interface 'lan'
		option type 'bridge'
		option ifname 'eth0'
		option proto 'static'
		option ipaddr '192.168.10.1'
		option netmask '255.255.255.0'
		option ip6assign '60'

	config interface 'wan'
		option ifname 'eth1'
		option proto 'dhcp'

	config interface 'wan6'
		option ifname 'eth1'
		option proto 'dhcpv6'
	EOF
else
	if [[ ! -f "${path}/lede/files/etc/config/network" ]]; then
		cat>${path}/lede/files/etc/config/network<<-EOF
		config interface 'loopback'
			option ifname 'lo'
			option proto 'static'
			option ipaddr '127.0.0.1'
			option netmask '255.0.0.0'

		config globals 'globals'
			option ula_prefix 'fd3f:2c76:9c66::/48'

		config interface 'lan'
			option type 'bridge'
			option ifname 'eth0'
			option proto 'static'
			option ipaddr '192.168.10.1'
			option netmask '255.255.255.0'
			option ip6assign '60'

		config interface 'wan'
			option ifname 'eth1'
			option proto 'dhcp'

		config interface 'wan6'
			option ifname 'eth1'
			option proto 'dhcpv6'
	EOF
	fi

fi
######
echo
#检查文件是否下载成功；
if [[ ! -s ${path}/lede/package/lean/default-settings/files/zzz-default-settings ]]; then # -s 判断文件长度是否不为0；
	clear
	echo
	echo "同步下载openwrt源码出错，请检查网络问题…"
	echo
	exit
fi
new_lede=`cat new_lede`
#判断old_lede是否存在，不存在创建
if [ ! -f "old_lede" ]; then
  clear
  echo "old_lede被删除正在创建！"
  sleep 0.1
  echo $new_lede > old_lede
fi
sleep 0.1
old_lede=`cat old_lede`
if [ "$new_lede" = "$old_lede" ]; then
	echo "no_update" > ${path}/nolede
else
	echo "update" > ${path}/nolede
	echo $new_lede > old_lede
fi
echo
##ssr+
git -C ${path}/lede/feeds/helloworld pull >/dev/null 2>&1
git -C ${path}/lede/feeds/helloworld rev-parse HEAD > new_ssr
#增加xray的makefile文件
wget -P ${path}/lede/feeds/helloworld/xray-core https://raw.githubusercontent.com/fw876/helloworld/master/xray-core/Makefile -O  ${path}/lede/feeds/helloworld/xray-core/Makefile >/dev/null 2>&1
new_ssr=`cat new_ssr`
#判断old_ssr是否存在，不存在创建
if [ ! -f "old_ssr" ]; then
  echo "old_ssr被删除正在创建！"
  sleep 0.1
  echo $new_ssr > old_ssr
fi
sleep 0.1
old_ssr=`cat old_ssr`
if [ "$new_ssr" = "$old_ssr" ]; then
	echo "no_update" > ${path}/nossr
else
	echo "update" > ${path}/nossr
	echo $new_ssr > old_ssr
fi
echo
##xray
#由于源码xray位置改变，需要加入一个判断
if [ ! -d  "${path}/lede/feeds/helloworld/xray-core" ]; then
	clear
	echo
	echo "正在更新feeds源，请稍后…"
	cd ${path}/lede && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1
	cd ${path}
fi
echo
if [ ! -d  "xray_update" ]; then
	mkdir -p ${path}/xray_update
fi
sed -i 's/core.build=OpenWrt/core.build=lenyu/g' ${path}/lede/feeds/helloworld/xray-core/Makefile
#获取xray-core/Makefile最新的版本号信息并修改；
wget -qO- -t1 -T2 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g;s/v//g' > ${path}/xray_lastest
#sed 's/\"//g;s/,//g;s/ //g;s/v//g'利用sed数据查找替换；
new_xray=`cat ${path}/xray_lastest`
if [ ! -f ${path}/xray_update/xray_version ]; then
	echo $new_xray > ${path}/xray_update/xray_version
fi
old_xray_ver=`cat ${path}/xray_update/xray_version`
if [ "$new_xray" != "$old_xray_ver" ]; then
	echo $new_xray > ${path}/xray_update/xray_version
	echo "update" > ${path}/noxray
else
	echo "no_update" > ${path}/noxray
fi
echo
rm -rf ${path}/xray_lastest
#本地版本号；
grep "PKG_VERSION:=" ${path}/lede/feeds/helloworld/xray-core/Makefile | awk -F "=" '{print $2}' > ${path}/jud_Makefile
old_xray=`cat ${path}/jud_Makefile`
rm -rf ${path}/jud_Makefile
echo
if [ "$new_xray" != "$old_xray" ]; then
	sed -i "s/.*PKG_VERSION:=.*/PKG_VERSION:=$new_xray/" ${path}/lede/feeds/helloworld/xray-core/Makefile
	#计算xray最新发布版本源码哈希值
	PKG_SOURCE_URL=https://codeload.github.com/XTLS/xray-core/tar.gz/v${new_xray}?
	wget -P ${path}/xray_update "$PKG_SOURCE_URL" -O  ${path}/xray_update/xray-core.tar.gz >/dev/null 2>&1
	sleep 0.1
	sha256sum ${path}/xray_update/xray-core.tar.gz > ${path}/xray_update/xray-core.tar.gz.sha256sum
	grep "xray-core.tar.gz" ${path}/xray_update/xray-core.tar.gz.sha256sum | awk -F " " '{print $1}' | sed 's/ //g' > ${path}/xray_update/xray-core_sha256sum
	echo
	xray_sha256sum=`cat ${path}/xray_update/xray-core_sha256sum`
	rm -rf ${path}/xray_update/xray-core.tar.gz.sha256sum
	rm -rf ${path}/xray_update/xray-core_sha256sum
	rm -rf ${path}/xray_update/xray-core.tar.gz
	sed -i "s/.*PKG_HASH:=.*/PKG_HASH:=$xray_sha256sum/" ${path}/lede/feeds/helloworld/xray-core/Makefile
	echo "update" > ${path}/noxray
fi
echo
##passwall
git -C ${path}/lede/feeds/passwall pull >/dev/null 2>&1
git -C ${path}/lede/feeds/passwall rev-parse HEAD > new_passw
new_passw=`cat new_passw`
#判断old_passw是否存在，不存在创建
if [ ! -f "old_passw" ]; then
  echo "old_passw被删除正在创建！"
  sleep 0.1
  echo $new_passw > old_passw
fi
sleep 0.1
old_passw=`cat old_passw`
if [ "$new_passw" = "$old_passw" ]; then
	echo "no_update" > ${path}/nopassw
else
	echo "update" > ${path}/nopassw
	echo $new_passw > old_passw
fi
echo
##openclash
git -C ${path}/lede/package/luci-app-openclash  pull >/dev/null 2>&1
git -C ${path}/lede/package/luci-app-openclash  rev-parse HEAD > new_clash
new_clash=`cat new_clash`
#判断old_clash是否存在，不存在创建
if [ ! -f "old_clash" ]; then
  echo "old_ssr被删除正在创建！"
  sleep 0.1
  echo $new_clash > old_clash
fi
sleep 0.1
old_clash=`cat old_clash`
if [ "$new_clash" = "$old_clash" ]; then
	echo "no_update" > ${path}/noclash
else
	echo "update" > ${path}/noclash
	echo $new_clash > old_clash
fi
##luci-theme-argon
git -C ${path}/lede/package/lean/luci-theme-argon  pull >/dev/null 2>&1
echo
sleep 0.1
####智能判断并替换大雕openwrt版本号的变动并自定义格式####
#下载GitHub使用raw页面，-P 指定目录 -O强制覆盖效果；
wget -P ${path}/wget https://raw.githubusercontent.com/coolsnowwolf/lede/master/package/lean/default-settings/files/zzz-default-settings -O  ${path}/wget/zzz-default-settings >/dev/null 2>&1
sleep 0.3
#-s代表文件存在不为空,!将他取反
if [ -s  "${path}/wget/zzz-default-settings" ]; then
	grep "DISTRIB_REVISION=" ${path}/wget/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION1
	new_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION1`
	#本地的文件，作为判断
	grep "DISTRIB_REVISION=" ${path}/lede/package/lean/default-settings/files/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION3
	old_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION3`
	#新旧判断是否执行替换R自定义版本…
	if [ "${new_DISTRIB_REVISION}_dev_Len yu" != "${old_DISTRIB_REVISION}" ]; then #版本号相等且带_dev_Len yu的情况，则不变，因此要不等于才动作；
		if [ "${new_DISTRIB_REVISION}" = "${old_DISTRIB_REVISION}" ]; then #版本号相等不带_dev_Len yu 的情况；
			sed -i "s/${old_DISTRIB_REVISION}/${new_DISTRIB_REVISION}_dev_Len yu/"  ${path}/lede/package/lean/default-settings/files/zzz-default-settings
		fi
	fi
	rm -rf ${path}/wget/DISTRIB_REVISION*
	rm -rf ${path}/wget/zzz-default-settings*
fi
####；
#总结判断;
#监测如果不存在rename.sh则创建该文件；
if [ ! -f "${path}/lede/rename.sh" ]; then
cat>${path}/lede/rename.sh<<EOF
#/usr/bin/bash
path=\$(dirname \$(readlink -f \$0))
cd \${path}
	if [ ! -f \${path}/bin/targets/x86/64/*combined.img.gz ] >/dev/null 2>&1; then
		echo
		echo "您编译时未选择压缩固件，故不进行重命名操作…"
		echo
		echo "为了减少固件体积，建议选择压缩（运行make menuconfig命令，在Target Images下勾选[*] GZip images）"
		echo
		exit 2
	fi
	rm -rf \${path}/bin/targets/x86/64/*Lenyu.img.gz
    	rm -rf \${path}/bin/targets/x86/64/packages
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic.manifest
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-rootfs-squashfs.img.gz
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.vmdk
    	rm -rf \${path}/bin/targets/x86/64/config.seed
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.vmdk
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-vmlinuz
	rm -rf \${path}/bin/targets/x86/64/config.buildinfo
	rm -rf \${path}/bin/targets/x86/64/feeds.buildinfo
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-kernel.bin
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.vmdk
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.vmdk
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img.gz
	rm -rf \${path}/bin/targets/x86/64/version.buildinfo
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img
    sleep 2
    str1=\`grep "KERNEL_PATCHVER:=" \${path}/target/linux/x86/Makefile | cut -d = -f 2\` #5.4
	ver414=\`grep "LINUX_VERSION-4.14 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver419=\`grep "LINUX_VERSION-4.19 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver54=\`grep "LINUX_VERSION-5.4 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	if [ "\$str1" = "5.4" ];then
		 mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_dev_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_uefi-gpt_dev_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.19" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_dev_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_uefi-gpt_dev_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.14" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_dev_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_uefi-gpt_dev_Lenyu.img.gz
		exit 0

	fi
EOF
fi
sleep 0.2
nolede=`cat ${path}/nolede`
noclash=`cat ${path}/noclash`
noxray=`cat ${path}/noxray`
nossr=`cat ${path}/nossr`
nopassw=`cat ${path}/nopassw`
#判断是否为x86机型编译，否是结束提示语改变
grep "CONFIG_TARGET_x86_64=y" ${path}/lede/.config  > ${path}/xray_update/sys_jud
sleep 0.5
if [[ ("$nolede" = "update") || ("$noclash" = "update") || ("$nossr" = "update" ) || ("$noxray" = "update") || ("$nopassw"  = "update" ) ]]; then
	clear
	echo
	echo "发现更新，请稍后…"
	clear
	echo
	echo "准备开始编译最新固件…"
	source /etc/environment && cd ${path}/lede && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1 && make defconfig && make -j8 download && make -j$(($(nproc) + 0)) V=s &&  bash rename.sh
	echo
	cd ${path}
	rm -rf ${path}/noxray
	rm -rf ${path}/noclash
	rm -rf ${path}/nolede
	rm -rf ${path}/nossr
	rm -rf ${path}/nopassw
	if [ -s  "${path}/xray_update/sys_jud" ]; then
		if [ ! -f ${path}/lede/bin/targets/x86/64/sha256sums ]; then
			echo
			echo "固件编译出错，请到${path}/lede/bin/targets/x86/64/目录下查看…"
			echo
			read -n 1 -p  "请回车继续…"
			menu
		else
			echo
			echo "固件编译成功，脚本退出！"
			echo
			echo "编译好的固件在${path}/lede/bin/targets/x86/64/目录下，enjoy！"
			echo
			rm -rf ${path}/lede/bin/targets/x86/64/sha256sums
			read -n 1 -p  "请回车继续…"
			menu
		fi
	else
		echo "您编译的是非x86架构的固件，请自行到${path}/lede/bin/targets/*目录里查找所编译的固件…"
	fi
fi
echo
if [[ ("$nolede" = "no_update") && ("$noclash" = "no_update") && ("$noxray" = "no_update") && ("$nossr" = "no_update" ) && ("$nopassw"  = "no_update" ) ]]; then
	clear
	echo
	echo "呃呃…检查lede/ssr+/xray/passwall/openclash源码，没有一个源码更新…开始进入强制更新模式…"
	echo
	echo "准备开始编译最新固件…"
	source /etc/environment && cd ${path}/lede && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1 && make defconfig && make -j8 download && make -j$(($(nproc) + 0)) V=s &&  bash rename.sh
	echo
	cd ${path}
	rm -rf ${path}/noxray
	rm -rf ${path}/noclash
	rm -rf ${path}/nolede
	rm -rf ${path}/nossr
	rm -rf ${path}/nopassw
	if [ -s  "${path}/xray_update/sys_jud" ]; then
		if [ ! -f ${path}/lede/bin/targets/x86/64/sha256sums ]; then
			echo
			echo "固件编译出错，请到${path}/lede/bin/targets/x86/64/目录下查看…"
			echo
			read -n 1 -p  "请回车继续…"
			menu
		else
			echo
			echo "固件编译成功，脚本退出！"
			echo
			echo "编译好的固件在${path}/lede/bin/targets/x86/64/目录下，enjoy！"
			echo
			rm -rf ${path}/lede/bin/targets/x86/64/sha256sums
			read -n 1 -p  "请回车继续…"
			menu
		fi
	else
		echo "您编译的是非x86架构的固件，请自行到${path}/lede/bin/targets/*目录里查找所编译的固件…"
	fi
fi
}


dev_noforce_update()
{
if [[  ! -d ${path}/lede  ]]; then
	clear
	echo
	echo -e "\033[31m警告：本地还没源码，请选脚本第1项目初始化…\033[0m"
	echo
	read -n 1 -p  "请回车继续…"
	echo
	menub
fi
cd ${path}
clear
echo
echo "脚本正在运行中…"
##lede
#由于源码xray位置改变，需要加入一个判断清除必要的文件
if [ ! -d  "${path}/lede/feeds/helloworld/xray-core" ]; then
	sed -i 's/#src-git helloworld/src-git helloworld/g'  ${path}/lede/feeds.conf.default
	rm -rf ${path}/lede/package/lean/xray
	rm -rf ${path}/lede/tmp
fi
#清理
rm -rf ${path}/lede/rename.sh
rm -rf ${path}/lede/package/lean/default-settings/files/zzz-default-settings
#rm -rf ${path}/lede/package/base-files/files/bin/config_generate
rm -rf ${path}/lede/feeds/helloworld/xray-core/Makefile
echo
git -C ${path}/lede pull >/dev/null 2>&1
git -C ${path}/lede rev-parse HEAD > new_lede
echo
wget -P ${path}/lede/package/lean/default-settings/files https://raw.githubusercontent.com/coolsnowwolf/lede/master/package/lean/default-settings/files/zzz-default-settings -O  ${path}/lede/package/lean/default-settings/files/zzz-default-settings >/dev/null 2>&1
echo
#####网络配置######
if [[ ! -d "${path}/lede/files/etc/config" ]]; then
	sed -i 's/192.168.10.1/192.168.1.1/g' ${path}/lede/package/base-files/files/bin/config_generate
	mkdir -p ${path}/lede/files/etc/config
	cat>${path}/lede/files/etc/config/network<<-EOF
	config interface 'loopback'
		option ifname 'lo'
		option proto 'static'
		option ipaddr '127.0.0.1'
		option netmask '255.0.0.0'

	config globals 'globals'
		option ula_prefix 'fd3f:2c76:9c66::/48'

	config interface 'lan'
		option type 'bridge'
		option ifname 'eth0'
		option proto 'static'
		option ipaddr '192.168.10.1'
		option netmask '255.255.255.0'
		option ip6assign '60'

	config interface 'wan'
		option ifname 'eth1'
		option proto 'dhcp'

	config interface 'wan6'
		option ifname 'eth1'
		option proto 'dhcpv6'
	EOF
else
	if [[ ! -f "${path}/lede/files/etc/config/network" ]]; then
		cat>${path}/lede/files/etc/config/network<<-EOF
		config interface 'loopback'
			option ifname 'lo'
			option proto 'static'
			option ipaddr '127.0.0.1'
			option netmask '255.0.0.0'

		config globals 'globals'
			option ula_prefix 'fd3f:2c76:9c66::/48'

		config interface 'lan'
			option type 'bridge'
			option ifname 'eth0'
			option proto 'static'
			option ipaddr '192.168.10.1'
			option netmask '255.255.255.0'
			option ip6assign '60'

		config interface 'wan'
			option ifname 'eth1'
			option proto 'dhcp'

		config interface 'wan6'
			option ifname 'eth1'
			option proto 'dhcpv6'
	EOF
	fi

fi
######
echo
#检查文件是否下载成功；
if [[ ( ! -s ${path}/lede/package/lean/default-settings/files/zzz-default-settings) ]]; then # -s 判断文件长度是否不为0；
	clear
	echo
	echo "同步下载openwrt源码出错，请检查网络问题…"
	echo
	exit
fi
new_lede=`cat new_lede`
#判断old_lede是否存在，不存在创建
if [ ! -f "old_lede" ]; then
  clear
  echo "old_lede被删除正在创建！"
  sleep 0.1
  echo $new_lede > old_lede
fi
sleep 0.1
old_lede=`cat old_lede`
if [ "$new_lede" = "$old_lede" ]; then
	echo "no_update" > ${path}/nolede
else
	echo "update" > ${path}/nolede
	echo $new_lede > old_lede
fi
echo
##ssr+
git -C ${path}/lede/feeds/helloworld pull >/dev/null 2>&1
git -C ${path}/lede/feeds/helloworld rev-parse HEAD > new_ssr
#增加xray的makefile文件
wget -P ${path}/lede/feeds/helloworld/xray-core https://raw.githubusercontent.com/fw876/helloworld/master/xray-core/Makefile -O  ${path}/lede/feeds/helloworld/xray-core/Makefile >/dev/null 2>&1
new_ssr=`cat new_ssr`
#判断old_ssr是否存在，不存在创建
if [ ! -f "old_ssr" ]; then
  echo "old_ssr被删除正在创建！"
  sleep 0.1
  echo $new_ssr > old_ssr
fi
sleep 0.1
old_ssr=`cat old_ssr`
if [ "$new_ssr" = "$old_ssr" ]; then
	echo "no_update" > ${path}/nossr
else
	echo "update" > ${path}/nossr
	echo $new_ssr > old_ssr
fi
echo
##xray
#由于源码xray位置改变，需要加入一个判断
if [ ! -d  "${path}/lede/feeds/helloworld/xray-core" ]; then
	clear
	echo
	echo "正在更新feeds源，请稍后…"
	cd ${path}/lede && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1
	cd ${path}
fi
echo
if [ ! -d  "xray_update" ]; then
	mkdir -p ${path}/xray_update
fi
sed -i 's/core.build=OpenWrt/core.build=lenyu/g' ${path}/lede/feeds/helloworld/xray-core/Makefile
#获取xray-core/Makefile最新的版本号信息并修改；
wget -qO- -t1 -T2 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g;s/v//g' > ${path}/xray_lastest
#sed 's/\"//g;s/,//g;s/ //g;s/v//g'利用sed数据查找替换；
new_xray=`cat ${path}/xray_lastest`
if [ ! -f ${path}/xray_update/xray_version ]; then
	echo $new_xray > ${path}/xray_update/xray_version
fi
old_xray_ver=`cat ${path}/xray_update/xray_version`
if [ "$new_xray" != "$old_xray_ver" ]; then
	echo $new_xray > ${path}/xray_update/xray_version
	echo "update" > ${path}/noxray
else
	echo "no_update" > ${path}/noxray
fi
echo
rm -rf ${path}/xray_lastest
#本地版本号；
grep "PKG_VERSION:=" ${path}/lede/feeds/helloworld/xray-core/Makefile | awk -F "=" '{print $2}' > ${path}/jud_Makefile
old_xray=`cat ${path}/jud_Makefile`
rm -rf ${path}/jud_Makefile
echo
if [ "$new_xray" != "$old_xray" ]; then
	sed -i "s/.*PKG_VERSION:=.*/PKG_VERSION:=$new_xray/" ${path}/lede/feeds/helloworld/xray-core/Makefile
	#计算xray最新发布版本源码哈希值
	PKG_SOURCE_URL=https://codeload.github.com/XTLS/xray-core/tar.gz/v${new_xray}?
	wget -P ${path}/xray_update "$PKG_SOURCE_URL" -O  ${path}/xray_update/xray-core.tar.gz >/dev/null 2>&1
	sleep 0.1
	sha256sum ${path}/xray_update/xray-core.tar.gz > ${path}/xray_update/xray-core.tar.gz.sha256sum
	grep "xray-core.tar.gz" ${path}/xray_update/xray-core.tar.gz.sha256sum | awk -F " " '{print $1}' | sed 's/ //g' > ${path}/xray_update/xray-core_sha256sum
	echo
	xray_sha256sum=`cat ${path}/xray_update/xray-core_sha256sum`
	rm -rf ${path}/xray_update/xray-core.tar.gz.sha256sum
	rm -rf ${path}/xray_update/xray-core_sha256sum
	rm -rf ${path}/xray_update/xray-core.tar.gz
	sed -i "s/.*PKG_HASH:=.*/PKG_HASH:=$xray_sha256sum/" ${path}/lede/feeds/helloworld/xray-core/Makefile
fi
echo
##passwall
git -C ${path}/lede/feeds/passwall pull >/dev/null 2>&1
git -C ${path}/lede/feeds/passwall rev-parse HEAD > new_passw
new_passw=`cat new_passw`
#判断old_passw是否存在，不存在创建
if [ ! -f "old_passw" ]; then
  echo "old_passw被删除正在创建！"
  sleep 0.1
  echo $new_passw > old_passw
fi
sleep 0.1
old_passw=`cat old_passw`
if [ "$new_passw" = "$old_passw" ]; then
	echo "no_update" > ${path}/nopassw
else
	echo "update" > ${path}/nopassw
	echo $new_passw > old_passw
fi
echo
##openclash
git -C ${path}/lede/package/luci-app-openclash  pull >/dev/null 2>&1
git -C ${path}/lede/package/luci-app-openclash  rev-parse HEAD > new_clash
new_clash=`cat new_clash`
#判断old_clash是否存在，不存在创建
if [ ! -f "old_clash" ]; then
  echo "old_ssr被删除正在创建！"
  sleep 0.1
  echo $new_clash > old_clash
fi
sleep 0.1
old_clash=`cat old_clash`
if [ "$new_clash" = "$old_clash" ]; then
	echo "no_update" > ${path}/noclash
else
	echo "update" > ${path}/noclash
	echo $new_clash > old_clash
fi
##luci-theme-argon
git -C ${path}/lede/package/lean/luci-theme-argon  pull >/dev/null 2>&1
echo
sleep 0.1
####智能判断并替换大雕openwrt版本号的变动并自定义格式####
#下载GitHub使用raw页面，-P 指定目录 -O强制覆盖效果；
wget -P ${path}/wget https://raw.githubusercontent.com/coolsnowwolf/lede/master/package/lean/default-settings/files/zzz-default-settings -O  ${path}/wget/zzz-default-settings >/dev/null 2>&1
sleep 0.3
#-s代表文件存在不为空,!将他取反
if [ -s  "${path}/wget/zzz-default-settings" ]; then
	grep "DISTRIB_REVISION=" ${path}/wget/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION1
	new_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION1`
	#本地的文件，作为判断
	grep "DISTRIB_REVISION=" ${path}/lede/package/lean/default-settings/files/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION3
	old_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION3`
	#新旧判断是否执行替换R自定义版本…
	if [ "${new_DISTRIB_REVISION}_dev_Len yu" != "${old_DISTRIB_REVISION}" ]; then #版本号相等且带_dev_Len yu的情况，则不变，因此要不等于才动作；
		if [ "${new_DISTRIB_REVISION}" = "${old_DISTRIB_REVISION}" ]; then #版本号相等不带_dev_Len yu 的情况；
			sed -i "s/${old_DISTRIB_REVISION}/${new_DISTRIB_REVISION}_dev_Len yu/"  ${path}/lede/package/lean/default-settings/files/zzz-default-settings
		fi
	fi
	rm -rf ${path}/wget/DISTRIB_REVISION*
	rm -rf ${path}/wget/zzz-default-settings*
fi
####；
#总结判断;
#监测如果不存在rename.sh则创建该文件；
if [ ! -f "${path}/lede/rename.sh" ]; then
cat>${path}/lede/rename.sh<<EOF
#/usr/bin/bash
path=\$(dirname \$(readlink -f \$0))
cd \${path}
	if [ ! -f \${path}/bin/targets/x86/64/*combined.img.gz ] >/dev/null 2>&1; then
		echo
		echo "您编译时未选择压缩固件，故不进行重命名操作…"
		echo
		echo "为了减少固件体积，建议选择压缩（运行make menuconfig命令，在Target Images下勾选[*] GZip images）"
		echo
		exit 2
	fi
	rm -rf \${path}/bin/targets/x86/64/*Lenyu.img.gz
    	rm -rf \${path}/bin/targets/x86/64/packages
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic.manifest
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-rootfs-squashfs.img.gz
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.vmdk
    	rm -rf \${path}/bin/targets/x86/64/config.seed
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.vmdk
    	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-vmlinuz
	rm -rf \${path}/bin/targets/x86/64/config.buildinfo
	rm -rf \${path}/bin/targets/x86/64/feeds.buildinfo
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-kernel.bin
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.vmdk
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.vmdk
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img.gz
	rm -rf \${path}/bin/targets/x86/64/version.buildinfo
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img
	rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img
    sleep 2
    str1=\`grep "KERNEL_PATCHVER:=" \${path}/target/linux/x86/Makefile | cut -d = -f 2\` #5.4
	ver414=\`grep "LINUX_VERSION-4.14 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver419=\`grep "LINUX_VERSION-4.19 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver54=\`grep "LINUX_VERSION-5.4 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	if [ "\$str1" = "5.4" ];then
		 mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_dev_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_uefi-gpt_dev_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.19" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_dev_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_uefi-gpt_dev_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.14" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_dev_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_uefi-gpt_dev_Lenyu.img.gz
		exit 0

	fi
EOF
fi
sleep 0.2
nolede=`cat ${path}/nolede`
noclash=`cat ${path}/noclash`
noxray=`cat ${path}/noxray`
nossr=`cat ${path}/nossr`
nopassw=`cat ${path}/nopassw`
#判断是否为x86机型编译，否是结束提示语改变
grep "CONFIG_TARGET_x86_64=y" ${path}/lede/.config  > ${path}/xray_update/sys_jud
sleep 0.5
if [[ ("$nolede" = "update") || ("$noclash" = "update") || ("$noxray" = "update") || ("$nossr" = "update" ) || ("$nopassw"  = "update" ) ]]; then
	clear
	echo
	echo "发现更新，请稍后…"
	clear
	echo
	echo "准备开始编译最新固件…"
	source /etc/environment && cd ${path}/lede && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1 && make defconfig && make -j8 download && make -j$(($(nproc) + 0)) V=s &&  bash rename.sh
	echo
	cd ${path}
	rm -rf ${path}/noxray
	rm -rf ${path}/noclash
	rm -rf ${path}/nolede
	rm -rf ${path}/nossr
	rm -rf ${path}/nopassw
	if [ -s  "${path}/xray_update/sys_jud" ]; then
		if [ ! -f ${path}/lede/bin/targets/x86/64/sha256sums ]; then
			echo
			echo "固件编译出错，请到${path}/lede/bin/targets/x86/64/目录下查看…"
			echo
			read -n 1 -p  "请回车继续…"
			menu
		else
			echo
			echo "固件编译成功，脚本退出！"
			echo
			echo "编译好的固件在${path}/lede/bin/targets/x86/64/目录下，enjoy！"
			echo
			rm -rf ${path}/lede/bin/targets/x86/64/sha256sums
			read -n 1 -p  "请回车继续…"
			menu
		fi
	else
		echo "您编译的是非x86架构的固件，请自行到${path}/lede/bin/targets/*目录里查找所编译的固件…"
	fi
fi
echo
if [[ ("$nolede" = "no_update") && ("$noclash" = "no_update") && ("$noxray" = "no_update") && ("$nossr" = "no_update" ) && ("$nopassw"  = "no_update" ) ]]; then
	clear
	echo
	echo "呃呃…检查lede/ssr+/xray/passwall/openclash源码，没有一个源码更新哟…还是稍安勿躁…"
fi
#脚本结束，准备最后的清理工作
rm -rf ${path}/noxray
rm -rf ${path}/noclash
rm -rf ${path}/nolede
rm -rf ${path}/nossr
rm -rf ${path}/nopassw
echo
echo
read -n 1 -p  "请回车继续…"
menu
}



sta_force_update()
{
if [[  ! -d ${path}/openwrt  ]]; then
	clear
	echo
	echo -e "\033[31m警告：本地还没源码，请选脚本第1项目初始化…\033[0m"
	echo
	read -n 1 -p  "请回车继续…"
	echo
	menub
fi
cd ${path}
clear
echo
echo "脚本正在运行中…"
##openwrt
#由于源码xray位置改变，需要加入一个判断清除必要的文件
if [ ! -d  "${path}/openwrt/feeds/helloworld/xray-core" ]; then
	sed -i 's/#src-git helloworld/src-git helloworld/g'  ${path}/openwrt/feeds.conf.default
	rm -rf ${path}/openwrt/package/lean/xray
	rm -rf ${path}/openwrt/tmp
fi
#清理
rm -rf ${path}/openwrt/rename.sh
rm -rf ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings
#rm -rf ${path}/openwrt/package/base-files/files/bin/config_generate
rm -rf ${path}/openwrt/feeds/helloworld/xray-core/Makefile
echo
git -C ${path}/openwrt pull >/dev/null 2>&1
git -C ${path}/openwrt rev-parse HEAD > new_openwrt
echo
wget -P ${path}/openwrt/package/lean/default-settings/files https://raw.githubusercontent.com/coolsnowwolf/openwrt/lede-17.01/package/lean/default-settings/files/zzz-default-settings -O  ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings >/dev/null 2>&1
echo
#####网络配置######
if [[ ! -d "${path}/openwrt/files/etc/config" ]]; then
	sed -i 's/192.168.10.1/192.168.1.1/g' ${path}/openwrt/package/base-files/files/bin/config_generate
	mkdir -p ${path}/openwrt/files/etc/config
	cat>${path}/openwrt/files/etc/config/network<<-EOF
	config interface 'loopback'
		option ifname 'lo'
		option proto 'static'
		option ipaddr '127.0.0.1'
		option netmask '255.0.0.0'

	config globals 'globals'
		option ula_prefix 'fd3f:2c76:9c66::/48'

	config interface 'lan'
		option type 'bridge'
		option ifname 'eth0'
		option proto 'static'
		option ipaddr '192.168.10.1'
		option netmask '255.255.255.0'
		option ip6assign '60'

	config interface 'wan'
		option ifname 'eth1'
		option proto 'dhcp'

	config interface 'wan6'
		option ifname 'eth1'
		option proto 'dhcpv6'
	EOF
else
	if [[ ! -f "${path}/openwrt/files/etc/config/network" ]]; then
		cat>${path}/openwrt/files/etc/config/network<<-EOF
		config interface 'loopback'
			option ifname 'lo'
			option proto 'static'
			option ipaddr '127.0.0.1'
			option netmask '255.0.0.0'

		config globals 'globals'
			option ula_prefix 'fd3f:2c76:9c66::/48'

		config interface 'lan'
			option type 'bridge'
			option ifname 'eth0'
			option proto 'static'
			option ipaddr '192.168.10.1'
			option netmask '255.255.255.0'
			option ip6assign '60'

		config interface 'wan'
			option ifname 'eth1'
			option proto 'dhcp'

		config interface 'wan6'
			option ifname 'eth1'
			option proto 'dhcpv6'
	EOF
	fi

fi
######
echo
#检查文件是否下载成功；
if [[ ( ! -s ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings) ]]; then # -s 判断文件长度是否不为0；
clear
echo
	echo "同步下载openwrt源码出错，请检查网络问题…"
echo
	exit
fi
new_openwrt=`cat new_openwrt`
#判断old_openwrt是否存在，不存在创建
if [ ! -f "old_openwrt" ]; then
  clear
  echo "old_openwrt被删除正在创建！"
  sleep 0.1
  echo $new_openwrt > old_openwrt
fi
sleep 0.1
old_openwrt=`cat old_openwrt`
if [ "$new_openwrt" = "$old_openwrt" ]; then
	echo "no_update" > ${path}/noopenwrt
else
	echo "update" > ${path}/noopenwrt
	echo $new_openwrt > old_openwrt
fi
echo
##ssr+
git -C ${path}/openwrt/feeds/helloworld pull >/dev/null 2>&1
git -C ${path}/openwrt/feeds/helloworld rev-parse HEAD > new_ssr
#增加xray的makefile文件
wget -P ${path}/openwrt/feeds/helloworld/xray-core https://raw.githubusercontent.com/fw876/helloworld/master/xray-core/Makefile -O  ${path}/openwrt/feeds/helloworld/xray-core/Makefile >/dev/null 2>&1
new_ssr=`cat new_ssr`
#判断old_ssr是否存在，不存在创建
if [ ! -f "old_ssr" ]; then
  echo "old_ssr被删除正在创建！"
  sleep 0.1
  echo $new_ssr > old_ssr
fi
sleep 0.1
old_ssr=`cat old_ssr`
if [ "$new_ssr" = "$old_ssr" ]; then
	echo "no_update" > ${path}/nossr
else
	echo "update" > ${path}/nossr
	echo $new_ssr > old_ssr
fi
echo
##xray
#由于源码xray位置改变，需要加入一个判断
if [ ! -d  "${path}/openwrt/feeds/helloworld/xray-core" ]; then
	clear
	echo
	echo "正在更新feeds源，请稍后…"
	cd ${path}/openwrt && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1
	cd ${path}
fi
echo
if [ ! -d  "xray_update" ]; then
	mkdir -p ${path}/xray_update
fi
sed -i 's/core.build=OpenWrt/core.build=lenyu/' ${path}/openwrt/feeds/helloworld/xray-core/Makefile
#获取xray-core/Makefile最新的版本号信息并修改；
wget -qO- -t1 -T2 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g;s/v//g' > ${path}/xray_lastest
#sed 's/\"//g;s/,//g;s/ //g;s/v//g'利用sed数据查找替换；
new_xray=`cat ${path}/xray_lastest`
if [ ! -f ${path}/xray_update/xray_version ]; then
	echo $new_xray > ${path}/xray_update/xray_version
fi
old_xray_ver=`cat ${path}/xray_update/xray_version`
if [ "$new_xray" != "$old_xray_ver" ]; then
	echo $new_xray > ${path}/xray_update/xray_version
	echo "update" > ${path}/noxray
else
	echo "no_update" > ${path}/noxray
fi
echo
rm -rf ${path}/xray_lastest
#本地版本号；
grep "PKG_VERSION:=" ${path}/openwrt/feeds/helloworld/xray-core/Makefile | awk -F "=" '{print $2}' > ${path}/jud_Makefile
old_xray=`cat ${path}/jud_Makefile`
rm -rf ${path}/jud_Makefile
echo
if [ "$new_xray" != "$old_xray" ]; then
	sed -i "s/.*PKG_VERSION:=.*/PKG_VERSION:=$new_xray/" ${path}/openwrt/feeds/helloworld/xray-core/Makefile
	#计算xray最新发布版本源码哈希值
	PKG_SOURCE_URL=https://codeload.github.com/XTLS/xray-core/tar.gz/v${new_xray}?
	wget -P ${path}/xray_update "$PKG_SOURCE_URL" -O  ${path}/xray_update/xray-core.tar.gz >/dev/null 2>&1
	sleep 0.1
	sha256sum ${path}/xray_update/xray-core.tar.gz > ${path}/xray_update/xray-core.tar.gz.sha256sum
	grep "xray-core.tar.gz" ${path}/xray_update/xray-core.tar.gz.sha256sum | awk -F " " '{print $1}' | sed 's/ //g' > ${path}/xray_update/xray-core_sha256sum
	echo
	xray_sha256sum=`cat ${path}/xray_update/xray-core_sha256sum`
	rm -rf ${path}/xray_update/xray-core.tar.gz.sha256sum
	rm -rf ${path}/xray_update/xray-core_sha256sum
	rm -rf ${path}/xray_update/xray-core.tar.gz
	sed -i "s/.*PKG_HASH:=.*/PKG_HASH:=$xray_sha256sum/" ${path}/openwrt/feeds/helloworld/xray-core/Makefile
	echo "update" > ${path}/noxray
fi
##passwall
git -C ${path}/openwrt/feeds/passwall pull >/dev/null 2>&1
git -C ${path}/openwrt/feeds/passwall rev-parse HEAD > new_passw
new_passw=`cat new_passw`
#判断old_passw是否存在，不存在创建
if [ ! -f "old_passw" ]; then
  echo "old_passw被删除正在创建！"
  sleep 0.1
  echo $new_passw > old_passw
fi
sleep 0.1
old_passw=`cat old_passw`
if [ "$new_passw" = "$old_passw" ]; then
	echo "no_update" > ${path}/nopassw
else
	echo "update" > ${path}/nopassw
	echo $new_passw > old_passw
fi
echo
##openclash
# git -C ${path}/openwrt/package/luci-app-openclash  pull >/dev/null 2>&1
# git -C ${path}/openwrt/package/luci-app-openclash  rev-parse HEAD > new_clash
# new_clash=`cat new_clash`
#判断old_clash是否存在，不存在创建
# if [ ! -f "old_clash" ]; then
  # echo "old_ssr被删除正在创建！"
  # sleep 0.1
  # echo $new_clash > old_clash
# fi
# sleep 0.1
# old_clash=`cat old_clash`
# if [ "$new_clash" = "$old_clash" ]; then
	# echo "no_update" > ${path}/noclash
# else
	# echo "update" > ${path}/noclash
	# echo $new_clash > old_clash
# fi
##luci-theme-argon
git -C ${path}/openwrt/package/lean/luci-theme-argon  pull >/dev/null 2>&1
echo
sleep 0.1
####智能判断并替换大雕openwrt版本号的变动并自定义格式####
#下载GitHub使用raw页面，-P 指定目录 -O强制覆盖效果；
wget -P ${path}/wget https://raw.githubusercontent.com/coolsnowwolf/openwrt/lede-17.01/package/lean/default-settings/files/zzz-default-settings -O  ${path}/wget/zzz-default-settings >/dev/null 2>&1
sleep 0.3
#-s代表文件存在不为空,!将他取反
if [ -s  "${path}/wget/zzz-default-settings" ]; then
	grep "DISTRIB_REVISION=" ${path}/wget/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION1
	new_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION1`
	#本地的文件，作为判断
	grep "DISTRIB_REVISION=" ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION3
	old_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION3`
	#新旧判断是否执行替换R自定义版本…
	if [ "${new_DISTRIB_REVISION}_sta_Len yu" != "${old_DISTRIB_REVISION}" ]; then #版本号相等且带_dev_Len yu的情况，则不变，因此要不等于才动作；
		if [ "${new_DISTRIB_REVISION}" = "${old_DISTRIB_REVISION}" ]; then #版本号相等不带_sta_Len yu 的情况；
			sed -i "s/${old_DISTRIB_REVISION}/${new_DISTRIB_REVISION}_sta_Len yu/"  ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings
		fi
	fi
	rm -rf ${path}/wget/DISTRIB_REVISION*
	rm -rf ${path}/wget/zzz-default-settings*
fi
####；
#总结判断;
#监测如果不存在rename.sh则创建该文件；
if [ ! -f "${path}/openwrt/rename.sh" ]; then
cat>${path}/openwrt/rename.sh<<EOF
#/usr/bin/bash
path=\$(dirname \$(readlink -f \$0))
cd \${path}
	if [ ! -f \${path}/bin/targets/x86/64/*squashfs.img.gz ] >/dev/null 2>&1; then
		echo
		echo "您编译时未选择压缩固件，故不进行重命名操作…"
		echo
		echo "为了减少固件体积，建议选择压缩（运行make menuconfig命令，在Target Images下勾选[*] GZip images）"
		echo
		exit 2
	fi
	rm -rf \${path}/bin/targets/x86/64/*Lenyu.img.gz
        rm -rf \${path}/bin/targets/x86/64/packages
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic.manifest
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-rootfs-squashfs.img.gz
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.vmdk
        rm -rf \${path}/bin/targets/x86/64/config.seed
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.vmdk
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-vmlinuz
		rm -rf \${path}/bin/targets/x86/64/config.buildinfo
		rm -rf \${path}/bin/targets/x86/64/feeds.buildinfo
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-kernel.bin
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.vmdk
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.vmdk
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img.gz
		rm -rf \${path}/bin/targets/x86/64/version.buildinfo
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img
    sleep 2
    str1=\`grep "KERNEL_PATCHVER:=" \${path}/target/linux/x86/Makefile | cut -d = -f 2\` #5.4
	ver414=\`grep "LINUX_VERSION-4.14 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver419=\`grep "LINUX_VERSION-4.19 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver54=\`grep "LINUX_VERSION-5.4 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	if [ "\$str1" = "5.4" ];then
		 mv \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_sta_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_uefi-gpt_sta_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.19" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_sta_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_uefi-gpt_sta_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.14" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_sta_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_uefi-gpt_sta_Lenyu.img.gz
		exit 0

	fi
EOF
fi
sleep 0.2
noopenwrt=`cat ${path}/noopenwrt`
#noclash=`cat ${path}/noclash`
noxray=`cat ${path}/noxray`
nossr=`cat ${path}/nossr`
nopassw=`cat ${path}/nopassw`
#判断是否为x86机型编译，否是结束提示语改变
grep "CONFIG_TARGET_x86_64=y" ${path}/openwrt/.config  > ${path}/xray_update/sys_jud
sleep 0.5
if [[ ("$noopenwrt" = "update")  || ("$noxray" = "update") || ("$nossr" = "update" ) || ("$nopassw"  = "update" ) ]]; then
	clear
	echo
	echo "发现更新，请稍后…"
	clear
	echo
	echo "准备开始编译最新固件…"
	source /etc/environment && cd ${path}/openwrt && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1 && make defconfig && make -j8 download && make -j$(($(nproc) + 0)) V=s &&  bash rename.sh
	echo
	cd ${path}
	rm -rf ${path}/noxray
	rm -rf ${path}/noclash
	rm -rf ${path}/noopenwrt
	rm -rf ${path}/nossr
	rm -rf ${path}/nopassw
	if [ -s  "${path}/xray_update/sys_jud" ]; then
		if [ ! -f ${path}/openwrt/bin/targets/x86/64/sha256sums ]; then
			echo
			echo "固件编译出错，请到${path}/openwrt/bin/targets/x86/64/目录下查看…"
			echo
			read -n 1 -p  "请回车继续…"
			menu
		else
			echo
			echo "固件编译成功，脚本退出！"
			echo
			echo "编译好的固件在${path}/openwrt/bin/targets/x86/64/目录下，enjoy！"
			echo
			rm -rf ${path}/openwrt/bin/targets/x86/64/sha256sums
			read -n 1 -p  "请回车继续…"
			menu
		fi
	else
		echo "您编译的是非x86架构的固件，请自行到${path}/openwrt/bin/targets/*目录里查找所编译的固件…"
	fi
fi
echo
if [[ ("$noopenwrt" = "no_update") && ("$noxray" = "no_update") && ("$nossr" = "no_update" ) && ("$nopassw"  = "no_update" ) ]]; then
	clear
	echo
	echo "呃呃…检查openwrt/ssr+/xray/passwall/openclash源码，没有一个源码更新…开始进入强制更新模式…"
	echo
	echo "准备开始编译最新固件…"
	source /etc/environment && cd ${path}/openwrt && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1 && make defconfig && make -j8 download && make -j$(($(nproc) + 0)) V=s &&  bash rename.sh
	echo
	cd ${path}
	rm -rf ${path}/noxray
	rm -rf ${path}/noclash
	rm -rf ${path}/noopenwrt
	rm -rf ${path}/nossr
	rm -rf ${path}/nopassw
	if [ -s  "${path}/xray_update/sys_jud" ]; then
		if [ ! -f ${path}/openwrt/bin/targets/x86/64/sha256sums ]; then
			echo
			echo "固件编译出错，请到${path}/openwrt/bin/targets/x86/64/目录下查看…"
			echo
			read -n 1 -p  "请回车继续…"
			menu
		else
			echo
			echo "固件编译成功，脚本退出！"
			echo
			echo "编译好的固件在${path}/openwrt/bin/targets/x86/64/目录下，enjoy！"
			echo
			rm -rf ${path}/openwrt/bin/targets/x86/64/sha256sums
			read -n 1 -p  "请回车继续…"
			menu
		fi
	else
		echo "您编译的是非x86架构的固件，请自行到${path}/openwrt/bin/targets/*目录里查找所编译的固件…"
	fi
fi
}




sta_noforce_update()
{
if [[  ! -d ${path}/openwrt  ]]; then
	clear
	echo
	echo -e "\033[31m警告：本地还没源码，请选脚本第1项目初始化…\033[0m"
	echo
	read -n 1 -p  "请回车继续…"
	echo
	menub
fi
cd ${path}
clear
echo
echo "脚本正在运行中…"
##openwrt
#由于源码xray位置改变，需要加入一个判断清除必要的文件
if [ ! -d  "${path}/openwrt/feeds/helloworld/xray-core" ]; then
	sed -i 's/#src-git helloworld/src-git helloworld/g'  ${path}/openwrt/feeds.conf.default
	rm -rf ${path}/openwrt/package/lean/xray
	rm -rf ${path}/openwrt/tmp
fi
#清理
rm -rf ${path}/openwrt/rename.sh
rm -rf ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings
#rm -rf ${path}/openwrt/package/base-files/files/bin/config_generate
rm -rf ${path}/openwrt/feeds/helloworld/xray-core/Makefile
echo
git -C ${path}/openwrt pull >/dev/null 2>&1
git -C ${path}/openwrt rev-parse HEAD > new_openwrt
echo
wget -P ${path}/openwrt/package/lean/default-settings/files https://raw.githubusercontent.com/coolsnowwolf/openwrt/lede-17.01/package/lean/default-settings/files/zzz-default-settings -O  ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings >/dev/null 2>&1
echo
#####网络配置######
if [[ ! -d "${path}/openwrt/files/etc/config" ]]; then
	sed -i 's/192.168.10.1/192.168.1.1/g' ${path}/openwrt/package/base-files/files/bin/config_generate
	mkdir -p ${path}/openwrt/files/etc/config
	cat>${path}/openwrt/files/etc/config/network<<-EOF
	config interface 'loopback'
		option ifname 'lo'
		option proto 'static'
		option ipaddr '127.0.0.1'
		option netmask '255.0.0.0'

	config globals 'globals'
		option ula_prefix 'fd3f:2c76:9c66::/48'

	config interface 'lan'
		option type 'bridge'
		option ifname 'eth0'
		option proto 'static'
		option ipaddr '192.168.10.1'
		option netmask '255.255.255.0'
		option ip6assign '60'

	config interface 'wan'
		option ifname 'eth1'
		option proto 'dhcp'

	config interface 'wan6'
		option ifname 'eth1'
		option proto 'dhcpv6'
	EOF
else
	if [[ ! -f "${path}/openwrt/files/etc/config/network" ]]; then
		cat>${path}/openwrt/files/etc/config/network<<-EOF
		config interface 'loopback'
			option ifname 'lo'
			option proto 'static'
			option ipaddr '127.0.0.1'
			option netmask '255.0.0.0'

		config globals 'globals'
			option ula_prefix 'fd3f:2c76:9c66::/48'

		config interface 'lan'
			option type 'bridge'
			option ifname 'eth0'
			option proto 'static'
			option ipaddr '192.168.10.1'
			option netmask '255.255.255.0'
			option ip6assign '60'

		config interface 'wan'
			option ifname 'eth1'
			option proto 'dhcp'

		config interface 'wan6'
			option ifname 'eth1'
			option proto 'dhcpv6'
		EOF
	fi

fi
######
echo
#检查文件是否下载成功；
if [[ ( ! -s ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings) ]]; then # -s 判断文件长度是否不为0；
clear
echo
	echo "同步下载openwrt源码出错，请检查网络问题…"
echo
	exit
fi
new_openwrt=`cat new_openwrt`
#判断old_openwrt是否存在，不存在创建
if [ ! -f "old_openwrt" ]; then
  clear
  echo "old_openwrt被删除正在创建！"
  sleep 0.1
  echo $new_openwrt > old_openwrt
fi
sleep 0.1
old_openwrt=`cat old_openwrt`
if [ "$new_openwrt" = "$old_openwrt" ]; then
	echo "no_update" > ${path}/noopenwrt
else
	echo "update" > ${path}/noopenwrt
	echo $new_openwrt > old_openwrt
fi
echo
##ssr+
git -C ${path}/openwrt/feeds/helloworld pull >/dev/null 2>&1
git -C ${path}/openwrt/feeds/helloworld rev-parse HEAD > new_ssr
#增加xray的makefile文件
wget -P ${path}/openwrt/feeds/helloworld/xray-core https://raw.githubusercontent.com/fw876/helloworld/master/xray-core/Makefile -O  ${path}/openwrt/feeds/helloworld/xray-core/Makefile >/dev/null 2>&1
new_ssr=`cat new_ssr`
#判断old_ssr是否存在，不存在创建
if [ ! -f "old_ssr" ]; then
  echo "old_ssr被删除正在创建！"
  sleep 0.1
  echo $new_ssr > old_ssr
fi
sleep 0.1
old_ssr=`cat old_ssr`
if [ "$new_ssr" = "$old_ssr" ]; then
	echo "no_update" > ${path}/nossr
else
	echo "update" > ${path}/nossr
	echo $new_ssr > old_ssr
fi
echo
##xray
#由于源码xray位置改变，需要加入一个判断
if [ ! -d  "${path}/openwrt/feeds/helloworld/xray-core" ]; then
	clear
	echo
	echo "正在更新feeds源，请稍后…"
	cd ${path}/openwrt && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1
	cd ${path}
fi
echo
if [ ! -d  "xray_update" ]; then
	mkdir -p ${path}/xray_update
fi
sed -i 's/core.build=OpenWrt/core.build=lenyu/g' ${path}/openwrt/feeds/helloworld/xray-core/Makefile
#获取xray-core/Makefile最新的版本号信息并修改；
wget -qO- -t1 -T2 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g;s/v//g' > ${path}/xray_lastest
#sed 's/\"//g;s/,//g;s/ //g;s/v//g'利用sed数据查找替换；
new_xray=`cat ${path}/xray_lastest`
if [ ! -f ${path}/xray_update/xray_version ]; then
	echo $new_xray > ${path}/xray_update/xray_version
fi
old_xray_ver=`cat ${path}/xray_update/xray_version`
if [ "$new_xray" != "$old_xray_ver" ]; then
	echo $new_xray > ${path}/xray_update/xray_version
	echo "update" > ${path}/noxray
else
	echo "no_update" > ${path}/noxray
fi
echo
rm -rf ${path}/xray_lastest
#本地版本号；
grep "PKG_VERSION:=" ${path}/openwrt/feeds/helloworld/xray-core/Makefile | awk -F "=" '{print $2}' > ${path}/jud_Makefile
old_xray=`cat ${path}/jud_Makefile`
rm -rf ${path}/jud_Makefile
echo
if [ "$new_xray" != "$old_xray" ]; then
	sed -i "s/.*PKG_VERSION:=.*/PKG_VERSION:=$new_xray/" ${path}/openwrt/feeds/helloworld/xray-core/Makefile
	#计算xray最新发布版本源码哈希值
	PKG_SOURCE_URL=https://codeload.github.com/XTLS/xray-core/tar.gz/v${new_xray}?
	wget -P ${path}/xray_update "$PKG_SOURCE_URL" -O  ${path}/xray_update/xray-core.tar.gz >/dev/null 2>&1
	sleep 0.1
	sha256sum ${path}/xray_update/xray-core.tar.gz > ${path}/xray_update/xray-core.tar.gz.sha256sum
	grep "xray-core.tar.gz" ${path}/xray_update/xray-core.tar.gz.sha256sum | awk -F " " '{print $1}' | sed 's/ //g' > ${path}/xray_update/xray-core_sha256sum
	echo
	xray_sha256sum=`cat ${path}/xray_update/xray-core_sha256sum`
	rm -rf ${path}/xray_update/xray-core.tar.gz.sha256sum
	rm -rf ${path}/xray_update/xray-core_sha256sum
	rm -rf ${path}/xray_update/xray-core.tar.gz
	sed -i "s/.*PKG_HASH:=.*/PKG_HASH:=$xray_sha256sum/" ${path}/openwrt/feeds/helloworld/xray-core/Makefile
	echo "update" > ${path}/noxray
fi
##passwall
git -C ${path}/openwrt/feeds/passwall pull >/dev/null 2>&1
git -C ${path}/openwrt/feeds/passwall rev-parse HEAD > new_passw
new_passw=`cat new_passw`
#判断old_passw是否存在，不存在创建
if [ ! -f "old_passw" ]; then
  echo "old_passw被删除正在创建！"
  sleep 0.1
  echo $new_passw > old_passw
fi
sleep 0.1
old_passw=`cat old_passw`
if [ "$new_passw" = "$old_passw" ]; then
	echo "no_update" > ${path}/nopassw
else
	echo "update" > ${path}/nopassw
	echo $new_passw > old_passw
fi
echo
# ##openclash
# git -C ${path}/openwrt/package/luci-app-openclash  pull >/dev/null 2>&1
# git -C ${path}/openwrt/package/luci-app-openclash  rev-parse HEAD > new_clash
# new_clash=`cat new_clash`
#判断old_clash是否存在，不存在创建
# if [ ! -f "old_clash" ]; then
  # echo "old_ssr被删除正在创建！"
  # sleep 0.1
  # echo $new_clash > old_clash
# fi
# sleep 0.1
# old_clash=`cat old_clash`
# if [ "$new_clash" = "$old_clash" ]; then
	# echo "no_update" > ${path}/noclash
# else
	# echo "update" > ${path}/noclash
	# echo $new_clash > old_clash
# fi
##luci-theme-argon
git -C ${path}/openwrt/package/lean/luci-theme-argon  pull >/dev/null 2>&1
echo
sleep 0.1
####智能判断并替换大雕openwrt版本号的变动并自定义格式####
#下载GitHub使用raw页面，-P 指定目录 -O强制覆盖效果；
wget -P ${path}/wget https://raw.githubusercontent.com/coolsnowwolf/openwrt/lede-17.01/package/lean/default-settings/files/zzz-default-settings -O  ${path}/wget/zzz-default-settings >/dev/null 2>&1
sleep 0.3
#-s代表文件存在不为空,!将他取反
if [ -s  "${path}/wget/zzz-default-settings" ]; then
	grep "DISTRIB_REVISION=" ${path}/wget/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION1
	new_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION1`
	#本地的文件，作为判断
	grep "DISTRIB_REVISION=" ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings | cut -d \' -f 2 > ${path}/wget/DISTRIB_REVISION3
	old_DISTRIB_REVISION=`cat ${path}/wget/DISTRIB_REVISION3`
	#新旧判断是否执行替换R自定义版本…
	if [ "${new_DISTRIB_REVISION}_sta_Len yu" != "${old_DISTRIB_REVISION}" ]; then #版本号相等且带_dev_Len yu的情况，则不变，因此要不等于才动作；
		if [ "${new_DISTRIB_REVISION}" = "${old_DISTRIB_REVISION}" ]; then #版本号相等不带_sta_Len yu 的情况；
			sed -i "s/${old_DISTRIB_REVISION}/${new_DISTRIB_REVISION}_sta_Len yu/"  ${path}/openwrt/package/lean/default-settings/files/zzz-default-settings
		fi
	fi
	rm -rf ${path}/wget/DISTRIB_REVISION*
	rm -rf ${path}/wget/zzz-default-settings*
fi
####；
#总结判断;
#监测如果不存在rename.sh则创建该文件；
if [ ! -f "${path}/openwrt/rename.sh" ]; then
cat>${path}/openwrt/rename.sh<<EOF
#/usr/bin/bash
path=\$(dirname \$(readlink -f \$0))
cd \${path}
	if [ ! -f \${path}/bin/targets/x86/64/*squashfs.img.gz ] >/dev/null 2>&1; then
		echo
		echo "您编译时未选择压缩固件，故不进行重命名操作…"
		echo
		echo "为了减少固件体积，建议选择压缩（运行make menuconfig命令，在Target Images下勾选[*] GZip images）"
		echo
		exit 2
	fi
	rm -rf \${path}/bin/targets/x86/64/*Lenyu.img.gz
        rm -rf \${path}/bin/targets/x86/64/packages
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic.manifest
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-rootfs-squashfs.img.gz
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.vmdk
        rm -rf \${path}/bin/targets/x86/64/config.seed
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.vmdk
        rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-vmlinuz
		rm -rf \${path}/bin/targets/x86/64/config.buildinfo
		rm -rf \${path}/bin/targets/x86/64/feeds.buildinfo
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-kernel.bin
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.vmdk
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.vmdk
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img.gz
		rm -rf \${path}/bin/targets/x86/64/version.buildinfo
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img
		rm -rf \${path}/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-rootfs.img
    sleep 2
    str1=\`grep "KERNEL_PATCHVER:=" \${path}/target/linux/x86/Makefile | cut -d = -f 2\` #5.4
	ver414=\`grep "LINUX_VERSION-4.14 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver419=\`grep "LINUX_VERSION-4.19 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	ver54=\`grep "LINUX_VERSION-5.4 =" \${path}/include/kernel-version.mk | cut -d . -f 3\`
	if [ "\$str1" = "5.4" ];then
		 mv \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_sta_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver54}_uefi-gpt_sta_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.19" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_sta_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver419}_uefi-gpt_sta_Lenyu.img.gz
		exit 0
	elif [ "\$str1" = "4.14" ];then
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-combined-squashfs.img.gz      \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_sta_Lenyu.img.gz
		mv \${path}/bin/targets/x86/64/openwrt-x86-64-uefi-gpt-squashfs.img.gz  \${path}/bin/targets/x86/64/openwrt_x86-64-\`date '+%m%d'\`_\${str1}.\${ver414}_uefi-gpt_sta_Lenyu.img.gz
		exit 0

	fi
EOF
fi
sleep 0.2
noopenwrt=`cat ${path}/noopenwrt`
#noclash=`cat ${path}/noclash`
noxray=`cat ${path}/noxray`
nossr=`cat ${path}/nossr`
nopassw=`cat ${path}/nopassw`
#判断是否为x86机型编译，否是结束提示语改变
grep "CONFIG_TARGET_x86_64=y" ${path}/openwrt/.config  > ${path}/xray_update/sys_jud
sleep 0.5
if [[ ("$noopenwrt" = "update") || ("$noxray" = "update") || ("$nossr" = "update" ) || ("$nopassw"  = "update" ) ]]; then
	clear
	echo
	echo "发现更新，请稍后…"
	clear
	echo
	echo "准备开始编译最新固件…"
	source /etc/environment && cd ${path}/openwrt && ./scripts/feeds update -a >/dev/null 2>&1 && ./scripts/feeds install -a >/dev/null 2>&1 && make defconfig && make -j8 download && make -j$(($(nproc) + 0)) V=s &&  bash rename.sh
	echo
	cd ${path}
	rm -rf ${path}/noxray
	rm -rf ${path}/noclash
	rm -rf ${path}/noopenwrt
	rm -rf ${path}/nossr
	rm -rf ${path}/nopassw
	if [ -s  "${path}/xray_update/sys_jud" ]; then
		if [ ! -f ${path}/openwrt/bin/targets/x86/64/sha256sums ]; then
			echo
			echo "固件编译出错，请到${path}/openwrt/bin/targets/x86/64/目录下查看…"
			echo
			read -n 1 -p  "请回车继续…"
			menu
		else
			echo
			echo "固件编译成功，脚本退出！"
			echo
			echo "编译好的固件在${path}/openwrt/bin/targets/x86/64/目录下，enjoy！"
			echo
			rm -rf ${path}/openwrt/bin/targets/x86/64/sha256sums
			read -n 1 -p  "请回车继续…"
			menu
		fi
	else
		echo "您编译的是非x86架构的固件，请自行到${path}/openwrt/bin/targets/*目录里查找所编译的固件…"
	fi
fi
echo
if [[ ("$noopenwrt" = "no_update")  && ("$noxray" = "no_update") && ("$nossr" = "no_update" ) && ("$nopassw"  = "no_update" ) ]]; then
	clear
	echo
	echo "呃呃…检查openwrt/ssr+/xray/passwall/openclash源码，没有一个源码更新哟…还是稍安勿躁…"
fi
#脚本结束，准备最后的清理工作
rm -rf ${path}/noxray
rm -rf ${path}/noclash
rm -rf ${path}/noopenwrt
rm -rf ${path}/nossr
rm -rf ${path}/nopassw
echo
echo
read -n 1 -p  "请回车继续…"
menu
}
_sys_judg
menu