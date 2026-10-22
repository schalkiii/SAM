# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 屏蔽数量
block_number=0
# 恢复数量
recovery_number=0

# 广告路径数组
ad_path=(
# 美团
"/data/data/com.sankuai.meituan.takeoutnew/files/cips/common/waimai/assets/ad"
"/data/media/0/Android/data/com.sankuai.meituan.takeoutnew/files/cips/common/waimai/assets/promotion"
"/data/data/com.sankuai.meituan/files/cips/common/mtplatform_group/assets/startup"
    
# 知乎
"/data/data/com.zhihu.android/files/ad"
    
# 哔哩哔哩
"/data/data/tv.danmaku.bili/files/res_cache"
"/data/data/tv.danmaku.bili/files/update"
"/data/data/tv.danmaku.bili/app_mod_resource"
"/data/data/com.bilibili.app.in/app_mod_resource"
"/data/media/0/Android/data/tv.danmaku.bili/cache/default/journal"
"/data/data/tv.danmaku.bili/files/splash2"
"/data/data/com.cn21.ecloud/files/ecloud_current_screenad.obj"
"/data/data/tv.danmaku.bili/files/splash_top_view"
"/data/data/tv.danmaku.bili/files/resmanager_resource_*"
    
# 中国广电
"/data/data/com.ai.obc.cbn.app/files/splashShow"
    
# 酷我音乐
"/data/media/0/Android/data/cn.kuwo.player/files/KuwoMusic/.screenad"
"/data/data/cn.kuwo.player/app_adnet"
"/data/media/0/Android/data/cn.kuwo.player/files/KuwoMusic/.ad"
    
# 网易云音乐
"/data/media/0/Android/data/com.netease.cloudmusic/cache/Ad"
"/data/data/com.netease.cloudmusic/cache/MusicWebApp" 
"/data/media/0/netease/adcache"
"/data/media/0/netease/cloudmusic/Ad"
    
# 大麦
"/data/data/cn.damai/files/ad_dir"
    
# 顺丰
"/data/data/com.sf.activity/files/openScreenADsImg"
    
# 丰云行
"/data/media/0/Android/data/com.yongyou/files/Pictures"
    
# 猫耳FM
"/data/data/cn.missevan/cache/splash"
    
# 小米有品
"/data/data/com.xiaomi.youpin/shared_prefs/ad_prf.xml"
    
# 小爱音箱
"/data/media/0/Android/data/com.xiaomi.mico/files/data_cache/journal"
    
# 高德地图
"/data/media/0/autonavi/afpSplash"
"/data/media/0/autonavi/splash"
"/data/media/0/Android/data/com.autonavi.minimap/cache/ajxFileDownload/"
"/data/data/com.autonavi.minimap/files/LaunchDynamicResource"
"/data/data/com.autonavi.minimap/files/splash"
    
# 抖音
"/data/data/com.ss.android.ugc.aweme/files/im_common_resource/common_resource/scene_strategy/incentive_chat_group_panel_alpha_video_festival"
"/data/media/0/Android/data/com.ss.android.ugc.aweme/awemeSplashCache"
"/data/media/0/Android/data/com.ss.android.ugc.aweme/liveSplashCache"
"/data/media/0/Android/data/com.ss.android.ugc.aweme/splashCache"
    
# QQ
"/data/media/0/Android/data/com.tencent.mobileqq/files/vas_ad"
"/data/media/0/Tencent/MobileQQ/splahAD"
"/data/media/0/Android/data/com.tencent.mobileqq/MobileQQ/splahAD"
"/data/media/0/Android/data/com.tencent.mobileqq/Tencent/MobileQQ/vasSplashAD"
    
# 安居客
"/data/data/com.anjuke.android.app/cache/splash_ad"
    
# 买单吧
"/data/data/com.bankcomm.maidanba/files/imageCachePath"
"/data/data/com.bankcomm.maidanba/files/tabAdsPath"
    
# 中国移动
"/data/data/com.greenpoint.android.mc10086.activity/shared_prefs/default.xml"
"/data/data/com.greenpoint.android.mc10086.activity/cache/image_manager_disk_cache"
    
# YY
"/data/data/com.duowan.mobile/shared_prefs/CommonPref.xml"
    
# 米家
"/data/data/com.xiaomi.smarthome/files/sh_ads_file"
    
# 米游社
"/data/media/0/Android/data/com.mihoyo.hyperion/cache/splash"
    
# 小米社区
"/data/data/com.xiaomi.vipaccount/files/mmkv/mmkv.default"
    
# 天翼云盘
    
# 闲鱼
"/data/media/0/Android/data/com.taobao.idlefish/files/splash_ad_assets"
"/data/media/0/Android/data/com.taobao.idlefish/files/ad"
"/data/data/com.taobao.idlefish/cache/beizi"
    
# 航旅纵横
"/data/data/com.umetrip.android.msky.app/files/ad"
    
# 携程旅行
"/data/media/0/Android/data/ctrip.android.view/cache/CTADCache"
"/data/data/ctrip.android.view/files/CTAD"
    
# 智行火车票
"/data/media/0/Android/data/com.yipiao/files/CTADCache"
"/data/media/0/Android/data/com.yipiao/files/CTADSet"
    
# 京东
"/data/media/0/Android/data/com.jingdong.app.mall/cache/JDVideoFileDir"

# 豆瓣
"/data/data/com.douban.frodo/cache/douban_ad"

# 驾考宝典
"/data/data/com.handsgo.jiakao.android/cache/GDTDOWNLOAD"
"/data/media/0/Android/data/com.handsgo.jiakao.android/cache/reward_video_cache_*"
"/data/media/0/Android/data/com.handsgo.jiakao.android/cache/splash_ad_cache"

# 百度地图
"/data/data/com.baidu.BaiduMap/files/AdvertData"

# QQ浏览器
"/data/data/com.tencent.mtt/files/tad_cache"

# QQ音乐
"/data/data/com.tencent.qqmusic/app_adnet"
"/data/data/com.tencent.qqmusic/files/tad_cache"
"/data/media/0/qqmusic/splash"

# 人人影视PRO
"/data/data/com.yyets.pro/app_ad"

# 酷安
"/data/media/0/Android/data/com.coolapk.market/cachett_ad"
"/data/media/0/Android/data/com.coolapk.market/cache/splash_image"
"/data/media/0/Android/data/com.coolapk.market/cache/com_qq_e_download"
"/data/media/0/Android/data/com.coolapk.market/cache/pangle_com.byted.pangle"
"/data/media/0/Android/data/com.coolapk.market/cache/tt_tmpl_pkg"
"/data/media/0/Android/data/com.coolapk.market/files/TTCache"
"/data/media/0/Android/data/com.coolapk.market/cache/com.jd.jdsdk"

# keep
"/data/media/0/Android/data/com.gotokeep.keep/files/keep/ads"

# 今日头条
"/data/media/0/Android/data/com.ss.android.article.news/splashCache"

# 腾讯微视
"/data/media/0/Android/data/com.tencent.weishi/splash_cache"

# 酷狗音乐
"/data/media/0/kugou/.splash"
"/data/media/0/Android/data/com.kugou.android/files/kugou/.splash"

# 微博
"/data/media/0/sina/weibo/.weibo_ad_universal_cache"
"/data/media/0/sina/weibo/.weibo_refreshad_cache"
"/data/media/0/sina/weibo/.weibo_video_cache_new"
"/data/media/0/sina/weibo/.weiboadcache"
"/data/media/0/sina/weibo/storage/biz_keep/.weibo_ad_universal_cache"
"/data/media/0/sina/weibo/storage/biz_keep/.weibo_refreshad_cache"

# 淘宝
"/data/media/0/Android/data/com.taobao.taobao/files/acds"
"/data/data/com.taobao.taobao/files/bootimageresources"

# 咪咕
"/data/media/0/Mob"

# MIUI
"/data/media/0/miad"
"/data/media/0/Android/data/com.miui.systemAdSolution/files/miad"

# 有道词典
"/data/media/0/Android/data/com.youdao.dict/files/yd_sdk_path"

# 邮箱大师
"/data/data/com.netease.mail/cache/adcache1"
"/data/data/com.netease.mail/cache/adcache"

# 饿了么
"/data/data/me.ele/cache/splash"
"/data/data/me.ele/files/o2o_ad"

# 百度网盘
"/data/data/com.baidu.netdisk/files/default_ad_caches"
"/data/data/com.baidu.netdisk/cache/wind"
"/data/data/com.baidu.netdisk/files/imgCache"
"/data/data/com.baidu.netdisk/files/splash_res_caches"
"/data/data/com.baidu.netdisk/files/video_front_ad_caches"
"/data/data/com.baidu.netdisk/files/splash"

# 移动云盘
"/data/media/0/Android/data/com.chinamobile.mcloud/files/boot_logo"

# 飞猪旅行
"/data/data/com.taobao.trip/files/fliggy_splash"

# 汽水音乐
"/data/media/0/com.luna.music/cache/image_commercial_cache"
"/data/media/0/com.luna.music/cache/pangle_com.byted.pangle"
"/data/media/0/com.luna.music/files/splashCache"

# 微信小游戏广告
"/data/media/0/Android/data/com.tencent.mm/MicroMsg/wagamefiles/gamead"

# 书旗小说
"/data/data/com.shuqi.controller/files/noah_ads"
"/data/data/com.shuqi.controller/files/flash_ad_image"

# 小福家
"/data/data/com.coocaa.familychat/app_e_qq_com_setting_7d767d052a5753acb54b111c8a40c128/sdkCloudSetting.cfg"

# 堆糖
"/data/data/com.duitang.main/shared_prefs/ad_cache.xml"

# 同花顺
"/data/data/com.hexin.plat.android/cache/splash_images"
    
# 锦江荟
"/data/data/com.plateno.botaoota/cache/image_manager_disk_cache"

# 腾讯地图
"/data/data/com.tencent.map/databases/splash.db"

# 4399游戏盒
"/data/data/com.m4399.gamecenter/shared_prefs/com.m4399.gamecenter.app.xml"

# 今日头条
"/data/data/com.ss.android.article.news/files/splashCache"
   
# 驾考宝典
"/data/data/com.handsgo.jiakao.android/shared_prefs/mucangData.db.xml"
   
# Apkpure
"/data/data/com.apkpure.aegon/cache/splash"
   
# 酷狗音乐
"/data/media/0/Android/data/com.kugou.android/files/kugou/.splash_v4"
   
# 午夜AV
"/data/data/com.aabbc.cc/files/cn_jiguang_union_ads/"
"/data/data/com.aabbc.cc/shared_prefs/spUtils.xml"

# 掌上无畏契约
"/data/media/0/Android/data/com.tencent.apps.valorant/cache/splash"

# WakeUp课程表
"/data/data/com.suda.yzune.wakeupschedule/shared_prefs/com.baidu.homework.Preference.FastAdPreference.xml"
"/data/data/com.suda.yzune.wakeupschedule/shared_prefs/mobads_aplist_status_new.xml"
   
# 猫眼
"/data/media/0/Android/data/com.sankuai.movie/cache/maoyan_downlaod"
"/data/data/com.sankuai.movie/cache/cips/common/mtplatform_mtpicasso/assets/image_manager_disk_cache"
   
# 心悦俱乐部
"/data/data/com.tencent.tgclub/cache/image_manager_disk_cache"
   
# 瓜子二手车
"/data/data/com.ganji.android.haoche_c/files/guazi_theme_image"
   
# 小象超市
"/data/media/0/Android/data/com.meituan.retail.v.android/files/cips/common/waimai"
"/data/data/com.meituan.retail.v.android/cache/cips/common/mtplatform_mtpicasso/assets/image_manager_disk_cache"
   
# 中信银行
"/data/data/com.ecitic.bank.mobile/files/citic/advs"
   
# 江苏银行
"/data/data/cn.jsb.china/cache/images"
"/data/data/cn.jsb.china/files/jsbank/splash"  
   
# 滴滴出行
"/data/data/com.sdu.didi.psnger/cache/image_manager_disk_cache"

# 盒马
"/data/data/com.wudaokou.hippo/shared_prefs/splash.xml"
   
# 完美世界电竞
"/data/data/com.pwrd.steam.esports/shared_prefs/advertisement_sp_name.xml"
   
# 人卫
"/data/data/com.pmph.irenwei/cache/image_manager_disk_cache"
"/data/data/com.pmph.irenwei/files/ad.gif"

# 中国银河证券
"/data/data/com.galaxy.stock/files"

# 南方基金
"/data/media/0/Android/data/com.nanfangjijin.app/files/ad"
"/data/data/com.nanfangjijin.app/cache/image_manager_disk_cache"
   
# 银华利生宝
"/data/data/com.ihandy.fund/cache/image_manager_disk_cache"
"/data/media/0/Android/data/com.ihandy.fund/cache/download/splash"
   
# 中国移动云盘
"/data/media/0/Android/data/com.chinamobile.mcloud/files/M_Cloud/temp/bigcloudimage"

# 建信基金
"/data/data/com.ccb.zzb.activity/files/image"
   
# 大学搜题酱
"/data/media/0/Android/data/com.zmzx.college.search/cache/glide"
   
# 汽水音乐
)

# 备份后缀: 屏蔽时把原内容改名到 <路径>.samhold, 恢复时改回原名
# 为什么用"改名"而不是"复制到备份目录":
#   1. 同一文件系统内 rename 是原子的瞬时操作, 不复制数据 -> 零额外空间, 屏蔽几乎不耗时
#   2. 备份与原路径同生命周期: App 被卸载时 /data/data/<包名> 整体被删, 备份跟着消失, 不留垃圾
#   3. 恢复同样是一次瞬时 rename
HOLD_SUFFIX=".samhold"

# 排除列表: 这些路径不参与屏蔽
# /data/system/ifw 是 Android 的 Intent Firewall 规则目录(存放 .xml 规则, 由 system_server 扫描执行)
# 屏蔽它收益极低(目录本就几乎为空), 却会清掉用户或其它模块写入的 IFW 规则, 故默认排除
ad_exclude=(
"/data/system/ifw"
)

# 备份清单(记录被屏蔽的原路径, 放在模块目录外, 模块重装不会丢)
HOLD_LIST="/data/adb/SAM-ad-hold.list"

# 判断路径是否带 immutable 锁定
# 优先用 lsattr -d 精确取目录自身属性; 某些 busybox 不支持 -d, 回退到不带 -d 的写法
is_locked(){
    lsattr -d "${1}" 2>/dev/null | grep -q "i.*${1}" && return 0
    lsattr "${1}" 2>/dev/null | grep -q "i.*${1}" && return 0
    return 1
}

# 记录一条备份
hold_record(){
    mkdir -p "$(dirname "${HOLD_LIST}")" 2>/dev/null
    grep -qxF "${1}" "${HOLD_LIST}" 2>/dev/null && return 0
    echo "${1}" >> "${HOLD_LIST}"
}

# 移除一条备份记录
# 注意: 不能写成 grep ... && mv, 因为把最后一行也过滤掉时 grep 返回 1,
# && 短路会导致清单没更新, 那条记录会一直残留
hold_forget(){
    [ -f "${HOLD_LIST}" ] || return 0
    grep -vxF "${1}" "${HOLD_LIST}" 2>/dev/null > "${HOLD_LIST}.tmp" 2>/dev/null
    mv -f "${HOLD_LIST}.tmp" "${HOLD_LIST}" 2>/dev/null
    rm -f "${HOLD_LIST}.tmp" 2>/dev/null
}

# 判断路径是否是备份产物(备份目录或 App 期间新写内容的暂存)
# 通配符展开时会连带命中这些, 必须排除
is_hold_item(){
    case "${1}" in
        *"${HOLD_SUFFIX}") return 0 ;;
        *"${HOLD_SUFFIX}.samnew") return 0 ;;
    esac
    return 1
}

# 判断路径是否在排除列表里
is_excluded(){
    for exclude_path in ${ad_exclude[@]}; do
        [ "${1}" = "${exclude_path}" ] && return 0
    done
    return 1
}

# 广告屏蔽
# 与旧版的差别: 旧版 rm -rf 把内容真删了且无法恢复, 这里改为改名保留,
# 原位置仍建一个空的锁定目录, App 侧的效果与旧版一致(读不到广告资源), 但数据可还原
block_ad(){
    ad_target="${1}"

    # 在排除列表里则跳过
    is_excluded "${ad_target}" && return 0

    # 已锁定说明屏蔽过了, 避免重复处理
    is_locked "${ad_target}" && return 0

    # 路径不存在则跳过
    [ -e "${ad_target}" ] || return 0

    ad_hold="${ad_target}${HOLD_SUFFIX}"

    if [ -d "${ad_target}" ]; then
        # 目录: 改名保留原内容, 原位置重建空目录并锁定
        rm -rf "${ad_hold}" 2>/dev/null
        if mv "${ad_target}" "${ad_hold}" 2>/dev/null; then
            mkdir -p "${ad_target}" 2>/dev/null
            chattr +i "${ad_target}" 2>/dev/null
            hold_record "${ad_target}"
        else
            # 改名失败(跨文件系统等)则退回旧行为
            log "e" "改名保留失败, 退回直接清空: ${ad_target}"
            rm -rf "${ad_target}" 2>/dev/null
            mkdir -p "${ad_target}" 2>/dev/null
            chattr +i "${ad_target}" 2>/dev/null
        fi
    elif [ -f "${ad_target}" ]; then
        # 文件: 改名保留原内容, 原位置建空文件并锁定
        rm -f "${ad_hold}" 2>/dev/null
        if mv "${ad_target}" "${ad_hold}" 2>/dev/null; then
            : > "${ad_target}"
            chattr +i "${ad_target}" 2>/dev/null
            hold_record "${ad_target}"
        else
            log "e" "改名保留失败, 退回直接清空: ${ad_target}"
            : > "${ad_target}"
            chattr +i "${ad_target}" 2>/dev/null
        fi
    fi
    let "block_number++"
}

# 广告恢复
recovery_ad(){
    ad_target="${1}"
    ad_hold="${ad_target}${HOLD_SUFFIX}"

    # 有备份: 先解锁清掉我们建的空壳, 再把原内容移回
    if [ -e "${ad_hold}" ]; then
        if [ -e "${ad_target}" ]; then
            chattr -i "${ad_target}" 2>/dev/null
            if [ -d "${ad_target}" ]; then
                # 空目录直接删; 非空说明 App 期间又写了东西, 改名保留而不是删
                rmdir "${ad_target}" 2>/dev/null ||                     mv "${ad_target}" "${ad_target}.samnew" 2>/dev/null
            else
                rm -f "${ad_target}" 2>/dev/null
            fi
        fi
        if mv "${ad_hold}" "${ad_target}" 2>/dev/null; then
            hold_forget "${ad_target}"
        else
            log "e" "恢复失败, 备份仍在: ${ad_hold}"
        fi
        let "recovery_number++"
        return 0
    fi

    # 没有备份: 只处理旧版本屏蔽留下的锁定空壳
    # 旧版屏蔽时内容已被 rm 掉, 这里只能解锁并删除空壳, 原数据无法找回
    if [ -e "${ad_target}" ] && is_locked "${ad_target}"; then
        chattr -i "${ad_target}" 2>/dev/null
        if [ -d "${ad_target}" ]; then
            rmdir "${ad_target}" 2>/dev/null
        else
            rm -f "${ad_target}" 2>/dev/null
        fi
        let "recovery_number++"
    fi
}

# 运行
# 数组展开必须加引号: 不加会把含空格的路径按空格拆成几个词, 静默失效
# 加引号后含 * 的路径会保持字面量, 由下面的 case 分支显式做通配符展开
run(){
    for ad in "${ad_path[@]}"
    do
        [ -n "${ad}" ] || continue
        # 在排除列表里的路径直接跳过
        is_excluded "${ad}" && continue

        case "${ad}" in
            *\**)
                # 含通配符的路径: 展开成实际存在的项
                # 数组展开的结果不会被 shell 再次做通配符展开, 这里必须显式处理,
                # 否则带 * 的路径一直被当成字面量, 实际从未生效过
                for ad_item in ${ad}; do
                    [ -e "${ad_item}" ] || continue
                    # 通配符会连带匹配到备份目录本身(如 res_* 命中 res_001.samhold),
                    # 必须排除, 否则二次 block 会把备份再改名成 .samhold.samhold
                    is_hold_item "${ad_item}" && continue
                    ${1} "${ad_item}"
                done
                ;;
            *)
                [ -e "${ad}" ] && ${1} "${ad}"
                ;;
        esac
    done
    [ "${1}" = "block_ad" ] && log "i" "已屏蔽 ${block_number} 个" || log "i" "已恢复 ${recovery_number} 个"
}

# 恢复全部: 优先按备份清单精确处理, 再兜底扫一遍路径数组(处理旧版本屏蔽的)
recovery_all(){
    # 1) 备份清单里的(新方案屏蔽的)
    # 先复制一份再遍历: recovery_ad 内部会从清单里删条目, 边遍历边改会漏读
    hold_copy="${TMP_PATH}/ad_hold_copy.$$"
    [ -f "${HOLD_LIST}" ] && cp -f "${HOLD_LIST}" "${hold_copy}" 2>/dev/null
    if [ -s "${hold_copy}" ]; then
        while IFS= read -r hold_line; do
            [ -n "${hold_line}" ] || continue
            recovery_ad "${hold_line}"
        done < "${hold_copy}"
    fi
    rm -f "${hold_copy}" 2>/dev/null

    # 2) 路径数组里剩余的(旧版本屏蔽的, 没有备份记录)
    for ad in "${ad_path[@]}"
    do
        [ -n "${ad}" ] || continue
        is_excluded "${ad}" && continue
        case "${ad}" in
            *\**)
                for ad_item in ${ad}; do
                    [ -e "${ad_item}" ] || continue
                    is_hold_item "${ad_item}" && continue
                    # 已在第 1 步处理过的跳过
                    [ -e "${ad_item}${HOLD_SUFFIX}" ] && continue
                    recovery_ad "${ad_item}"
                done
                ;;
            *)
                [ -e "${ad}${HOLD_SUFFIX}" ] && continue
                recovery_ad "${ad}"
                ;;
        esac
    done
}

# 列出会被处理(或已处理)的 App 与路径
# 输出格式: APP|路径|状态|备份大小(KB), 供 WebUI 展示"影响范围"
list_ad(){
    app_name="其他"
    in_array=0

    ad_entries="${TMP_PATH}/ad_entries.$$"
    ad_attrs="${TMP_PATH}/ad_attrs.$$"
    ad_paths="${TMP_PATH}/ad_paths.$$"
    ad_holds="${TMP_PATH}/ad_holds.$$"
    ad_sizes="${TMP_PATH}/ad_sizes.$$"
    : > "${ad_entries}"
    : > "${ad_paths}"
    : > "${ad_holds}"
    : > "${ad_sizes}"

    # 第一遍: 解析数组, 记录 App、路径、是否存在、是否有备份
    while IFS= read -r line; do
        case "${line}" in
            "ad_path=("*)
                in_array=1
                continue
                ;;
        esac

        [ ${in_array} -eq 1 ] || continue
        # 数组结束: 容忍行尾空白与 CR
        case "${line}" in
            ")"*) break ;;
        esac

        case "${line}" in
            "# "*)
                app_name="${line#\# }"
                continue
                ;;
        esac

        # 只认整行就是一个双引号包裹的路径
        # 这里解析的是脚本自身源码, 不加严格判断的话,
        # 后面的函数体里任何带引号的行(例如 echo "${x}|${y}")都会被当成路径条目
        case "${line}" in
            '"'*'"') ;;
            *) continue ;;
        esac

        # 用参数展开取引号内的路径: 每行 sed 都要 fork 一次, 150 条会很慢
        ad_item="${line#*\"}"
        ad_item="${ad_item%%\"*}"
        [ -z "${ad_item}" ] && continue

        # 路径必须以 / 开头(设备上都是 /data/... ), 进一步过滤掉整行就是 "..." 的代码行
        # (例如 "${1}" "${ad_target}" 这种调用行也会匹配上面的双引号模式)
        case "${ad_item}" in
            /*) ;;
            [A-Za-z]:/*) ;;
            *) continue ;;
        esac

        # 排除列表里的路径不显示
        is_excluded "${ad_item}" && continue

        ad_hold_path="${ad_item}${HOLD_SUFFIX}"
        if [ -e "${ad_item}" ]; then
            if [ -e "${ad_hold_path}" ]; then
                echo "${app_name}|${ad_item}|2" >> "${ad_entries}"
            else
                echo "${app_name}|${ad_item}|1" >> "${ad_entries}"
            fi
            echo "${ad_item}" >> "${ad_paths}"
            [ -e "${ad_hold_path}" ] && echo "${ad_hold_path}" >> "${ad_holds}"
        else
            echo "${app_name}|${ad_item}|0" >> "${ad_entries}"
        fi
    done < "${0}"

    # 第二遍: 一次性读取所有存在路径的属性, 避免逐个 fork lsattr
    : > "${ad_attrs}"
    if [ -s "${ad_paths}" ] && command -v lsattr > /dev/null 2>&1; then
        # shellcheck disable=SC2046
        lsattr -d $(cat "${ad_paths}") 2>/dev/null > "${ad_attrs}"
    fi

    # 第三遍: 统计各备份占用
    : > "${ad_sizes}"
    if [ -s "${ad_holds}" ] && command -v du > /dev/null 2>&1; then
        while IFS= read -r hold_path; do
            [ -n "${hold_path}" ] || continue
            hold_size=$(du -sk "${hold_path}" 2>/dev/null | awk '{print $1}')
            [ -z "${hold_size}" ] && hold_size=0
            echo "${hold_path}|${hold_size}" >> "${ad_sizes}"
        done < "${ad_holds}"
    fi

    echo "APP|路径|状态|备份(KB)"

    # 用一个带区段标记的流喂给 awk:
    # 两个文件直接 FNR==NR 会在第一个文件为空时失效(空文件下 NR==FNR 恒成立)
    {
        echo "ATTRS"
        cat "${ad_attrs}"
        echo "SIZES"
        cat "${ad_sizes}"
        echo "ENTRIES"
        cat "${ad_entries}"
    } | awk '
        $0 == "ATTRS" { mode = "attrs"; next }
        $0 == "SIZES" { mode = "sizes"; next }
        $0 == "ENTRIES" { mode = "entries"; next }

        mode == "attrs" {
            flags = $1
            target = $0
            sub(/^[^[:space:]]+[[:space:]]+/, "", target)
            locked[target] = (flags ~ /i/)
            next
        }

        mode == "sizes" {
            count = split($0, parts, "|")
            if (count < 2) next
            size[parts[1]] = parts[2]
            next
        }

        mode == "entries" {
            count = split($0, parts, "|")
            if (count < 3) next
            hold_path = parts[2] ".samhold"
            kb = (hold_path in size) ? size[hold_path] : 0
            if (parts[3] == "0") {
                state = "不存在"
            } else if (parts[3] == "2") {
                state = (parts[2] in locked) ? "已锁定(有备份)" : "存在(有备份,未锁定)"
            } else {
                state = (parts[2] in locked) ? "已锁定(无备份)" : "存在未锁定"
            }
            print parts[1] "|" parts[2] "|" state "|" kb
        }
    '

    rm -f "${ad_entries}" "${ad_attrs}" "${ad_paths}" "${ad_holds}" "${ad_sizes}"
}

# 列出广告备份占用
list_hold(){
    total_size=0
    hold_count=0

    if [ ! -f "${HOLD_LIST}" ]; then
        echo "当前没有广告备份"
        return 0
    fi

    echo "路径|备份位置|占用(KB)"

    while IFS= read -r hold_line; do
        [ -n "${hold_line}" ] || continue
        hold_path="${hold_line}${HOLD_SUFFIX}"
        if [ ! -e "${hold_path}" ]; then
            # 备份已不在(可能 App 卸载时被一起删掉), 清掉这条记录
            hold_forget "${hold_line}"
            continue
        fi
        hold_size=$(du -sk "${hold_path}" 2>/dev/null | awk '{print $1}')
        [ -z "${hold_size}" ] && hold_size=0
        total_size=$((total_size + hold_size))
        hold_count=$((hold_count + 1))
        echo "${hold_line}|${hold_path}|${hold_size}"
    done < "${HOLD_LIST}"

    echo "合计 ${hold_count} 条, ${total_size} KB"
}

# 添加指令
case "$1" in
    block)
        log "i" "屏蔽 App 广告路径"
        run "block_ad"
        ;;
    recovery)
        log "i" "恢复 App 广告路径"
        recovery_all
        log "i" "已恢复 ${recovery_number} 个"
        ;;
    list)
        list_ad
        ;;
    hold)
        list_hold
        ;;
    *)
        echo "使用: block(屏蔽) | recovery(恢复) | list(列出影响范围) | hold(列出备份占用)"
        exit 1
        ;;
esac
