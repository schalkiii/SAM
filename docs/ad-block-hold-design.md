# 广告屏蔽改造方案：移走 + 保留备份

> 状态：**已实施**（v20261021.10）。本文档保留设计推导过程，实现细节以 `scripts/ad.sh` 为准。
> 关联问题：`scripts/ad.sh` 的 `block_ad()` 用 `rm -rf` 删除 App 数据目录且不可逆

## 1. 问题现状

`scripts/ad.sh` 的 `block_ad()` 逻辑：

```sh
if [ -d "${1}" ]; then
    rm -rf "${1}"      # 删除目录及全部内容
    mkdir -p "${1}"    # 重建空目录
    chattr +i "${1}"   # 锁定
elif [ -f "${1}" ]; then
    > "${1}"           # 清空文件
    chattr +i "${1}"
fi
```

`recovery_ad()` 只能 `rmdir` 空目录 / `rm` 空文件，**原数据在 `rm -rf` 那一刻就没了，无法恢复**。

### 影响面（对 `ad_path` 数组实测统计）

| 项 | 数量 | 说明 |
|---|---|---|
| 路径总数 | 153 | 去重后 148；再移除 `/data/system/ifw` 后为 147 |
| 重复条目 | 5 | 会被锁定守卫跳过，但影响范围列表里显示两遍 |
| `shared_prefs/*.xml` | 11 | **App 的 SharedPreferences 配置**，清空后 App 丢失本地设置 |
| `databases/*.db` | 1 | `com.tencent.map/databases/splash.db` |
| 非 App 私有目录 | 1 | `/data/system/ifw`（Android Intent Firewall 规则目录） |
| 含通配符 | 2 | `.../resmanager_resource_*`、`.../reward_video_cache_*` |

**通配符路径从未生效**：现有代码用 `[ -e "${ad}" ]` 判断存在性，字面量带 `*` 永远匹配不到，这两个路径实际一直没被屏蔽过。

### 为什么"刷了没感觉"

绝大多数条目确实是广告缓存目录，删掉后 App 重新下载资源即可；11 条 `shared_prefs` 里多数是广告开关配置，App 下次启动会用默认值重建。**现象不明显，但机制上不可逆**。

### 溯源

- `rm -rf` 机制：上游 `5MayRain/SAM` **2025-11-29**（`4c94440`，`ad.sh` 最早版本）引入
- `/data/system/ifw`：上游 **2026-08-30**（`8bc172a`）加入

两者都不是本 fork 引入的（fork 第一个 commit `7d8ea46` 已包含）。

## 2. 方案核心

把「删除内容」换成「**改名保留**」：

```
block:    mv <path> <path>.samhold   →  mkdir -p <path>  →  chattr +i <path>
recovery: chattr -i <path>            →  rmdir <path>(空才删)  →  mv <path>.samhold <path>
```

语义完全不变：App 看到的仍是「一个存在但为空、且不可写的目录」，广告资源读不到。
变化只有一个：**内容没被删，而是改名存在旁边，可随时还原**。

## 3. 为什么备份放在原位（in-place）而不是集中备份目录

| 维度 | in-place rename | 集中备份目录 + copy |
|---|---|---|
| 额外空间 | **0**（rename 不复制数据） | 占用等于被屏蔽内容总量 |
| 首次 block 耗时 | 139 次 rename，**瞬时**（同 fs 原子操作） | 139 次跨 fs copy，慢 |
| App 卸载后 | `/data/data/<pkg>` 整体被删，**备份自动消失**，不留垃圾 | 备份残留，需手动清理 |
| 恢复速度 | 瞬时 rename | 跨 fs copy 回来 |
| 检索 | 需 manifest 记录 | 目录即索引 |

选择 **in-place rename**，用 manifest 解决检索问题。

## 4. 改动清单

### 4.1 `scripts/ad.sh`

**新增常量与排除列表**

```sh
# 备份后缀：屏蔽时把原内容改名到 <path>.samhold，恢复时改回
HOLD_SUFFIX=".samhold"
# 排除列表：这些路径不参与屏蔽
# /data/system/ifw 是 Android Intent Firewall 规则目录，
# 屏蔽它收益极低(目录本就几乎为空)，却会清掉用户自己写的 IFW 规则
ad_exclude=(
"/data/system/ifw"
)
```

**`block_ad()` 改造**

```sh
block_ad(){
    ad_path_arg="${1}"
    # 在排除列表里则跳过
    for ad_skip in ${ad_exclude[@]}; do
        [ "${ad_path_arg}" = "${ad_skip}" ] && return
    done
    # 已锁定说明已屏蔽过，避免重复处理
    lsattr "${ad_path_arg}" 2>&1 | grep -q "i.*${ad_path_arg}" && return
    [ -e "${ad_path_arg}" ] || return

    ad_hold="${ad_path_arg}${HOLD_SUFFIX}"
    if [ -d "${ad_path_arg}" ]; then
        # 目录：改名保留原内容
        rm -rf "${ad_hold}" 2>/dev/null
        if mv "${ad_path_arg}" "${ad_hold}" 2>/dev/null; then
            mkdir -p "${ad_path_arg}" && chattr +i "${ad_path_arg}" 2>/dev/null
            hold_record "${ad_path_arg}"
        else
            # rename 失败(跨文件系统等)则退回旧行为
            rm -rf "${ad_path_arg}" 2>/dev/null
            mkdir -p "${ad_path_arg}" && chattr +i "${ad_path_arg}" 2>/dev/null
        fi
    elif [ -f "${ad_path_arg}" ]; then
        # 文件：改名保留原内容
        rm -f "${ad_hold}" 2>/dev/null
        if mv "${ad_path_arg}" "${ad_hold}" 2>/dev/null; then
            : > "${ad_path_arg}" && chattr +i "${ad_path_arg}" 2>/dev/null
            hold_record "${ad_path_arg}"
        else
            : > "${ad_path_arg}" && chattr +i "${ad_path_arg}" 2>/dev/null
        fi
    fi
    let "block_number++"
}
```

**`recovery_ad()` 改造**

```sh
recovery_ad(){
    ad_path_arg="${1}"
    ad_hold="${ad_path_arg}${HOLD_SUFFIX}"

    # 1) 解锁并清理我们建的空壳
    if [ -e "${ad_path_arg}" ]; then
        chattr -i "${ad_path_arg}" 2>/dev/null
        if [ -d "${ad_path_arg}" ]; then
            rmdir "${ad_path_arg}" 2>/dev/null
        else
            rm -f "${ad_path_arg}" 2>/dev/null
        fi
    fi

    # 2) 恢复原内容
    if [ -e "${ad_hold}" ]; then
        if [ -e "${ad_path_arg}" ]; then
            # 屏蔽期间 App 又写了东西：改名保留而不是删，避免丢数据
            mv "${ad_path_arg}" "${ad_path_arg}.samnew" 2>/dev/null || rm -rf "${ad_path_arg}" 2>/dev/null
        fi
        mv "${ad_hold}" "${ad_path_arg}" 2>/dev/null
        hold_forget "${ad_path_arg}"
    fi
    let "recovery_number++"
}
```

**`run()` 改造**：恢复时原路径可能已不存在但 `.samhold` 还在，需要一并处理。

```sh
run(){
    for ad in ${ad_path[@]}
    do
        if [ "${1}" = "recovery_ad" ]; then
            # 恢复时原路径或备份任一存在就要处理
            [ -e "${ad}" ] || [ -e "${ad}${HOLD_SUFFIX}" ] || continue
        else
            [ -n "${ad}" ] && [ -e "${ad}" ] || continue
        fi
        ${1} "${ad}"
    done
    ...
}
```

**manifest 维护**（`/data/adb/SAM-ad-hold.list`，放在模块目录外，模块重装不丢）

```sh
HOLD_LIST="/data/adb/SAM-ad-hold.list"
hold_record(){ grep -qxF "${1}" "${HOLD_LIST}" 2>/dev/null || echo "${1}" >> "${HOLD_LIST}"; }
hold_forget(){ grep -vxF "${1}" "${HOLD_LIST}" 2>/dev/null > "${HOLD_LIST}.t" && mv -f "${HOLD_LIST}.t" "${HOLD_LIST}"; }
```

用途：列出当前所有备份、发现孤儿（原路径已不在 `ad_path` 数组里的历史备份）。

**`list_ad()` 状态扩展**：3 态 → 5 态，并附备份大小

| 状态 | 含义 |
|---|---|
| 不存在 | 路径本身不存在 |
| 存在未锁定 | 正常状态，未屏蔽 |
| 已锁定(有备份) | 新方案屏蔽，数据保留在 `.samhold` |
| 已锁定(无备份) | 旧版本屏蔽的，原数据已删除，恢复不了 |
| 存在(属性未知) | `lsattr` 读不到 |

**新增子命令 `hold`**：输出备份清单与总占用

```sh
hold)
    # 逐条输出 路径 | 备份路径 | 占用大小
    # 末尾给出总占用
```

### 4.2 `webroot/index.html` + `webroot/js/main.js`

- 「影响范围」表格增加「备份大小」列
- 工具页「广告与 Hosts」区增加按钮：`data-script="ad.sh" data-args="hold"` → 「查看广告备份占用」

### 4.3 无需改动的部分

- `scripts/uninstall.sh` / `manual.sh uninstall` 已调用 `ad.sh recovery`，新逻辑下会自动把数据移回
- `scripts/service.sh` 调用 `ad.sh block` 的路径不变

## 5. 状态机

| 初始状态 | block 后 | recovery 后 |
|---|---|---|
| 目录有内容 | `path`=空目录(锁) / `path.samhold`=原内容 | `path`=原内容 ✅ |
| 文件有内容 | `path`=空文件(锁) / `path.samhold`=原内容 | `path`=原内容 ✅ |
| 旧版本已屏蔽(锁空目录, 无 `.samhold`) | 守卫跳过，不变 | 解锁 + 删空壳（原数据已丢，如实提示） |
| 路径不存在 | 跳过 | 跳过 |
| 屏蔽期间 App 又写入 | — | 新内容存到 `path.samnew`，原数据回填 `path` |
| 连续 block 两次 | 第二次被锁定守卫跳过 | — |
| rename 失败(跨 fs) | 回退旧行为（删除） | 同上 |

## 6. 兼容与迁移

- **老版本屏蔽过的路径**：`recovery` 走「无备份」分支，正常解锁清理，但原数据无法找回 —— UI 需明确提示「该路径由旧版本屏蔽，原数据已删除」
- **建议升级流程**：先执行一次「恢复」清掉旧空壳，再执行「屏蔽」走新逻辑
- **manifest 与老状态无关**：老状态没有 `.samhold`，manifest 里不会有记录

## 7. 空间与性能对比

| | 现状(`rm -rf`) | 新方案(rename) |
|---|---|---|
| 首次 block 耗时 | 139 次真删除 | 139 次 rename，**瞬时** |
| 额外空间占用 | 0 | **0**（rename 不复制） |
| 可逆性 | ❌ 不可逆 | ✅ 完全可逆 |
| 恢复耗时 | 无（数据没了） | 139 次 rename，瞬时 |

## 8. 顺带修掉的问题

1. **2 条通配符路径从未生效** —— 现状 `[ -e "字面量*"]` 恒假
   - 选项 A：支持 glob 展开（`for f in <glob>`），真正生效
   - 选项 B：直接从数组里删掉，承认这两条不做屏蔽
2. **5 条重复路径** —— 去重
3. **`/data/system/ifw`** —— 加入 `ad_exclude` 默认排除

## 9. 风险与取舍

| 风险 | 评估 | 对策 |
|---|---|---|
| `.samhold` 目录暴露在 App 私有目录里，App 遍历时可能看到 | 低 | 绝大多数 App 不遍历 `files/` 下未知目录；且旧方案是删空，App 看到的也是空目录 |
| App 卸载 → `/data/data/<pkg>` 整个删除 → 备份一起没了 | 可接受 | 与用户预期一致（卸载 App = 放弃该 App 的数据） |
| App 清理逻辑误删 `.samhold` | 极低 | 旧方案直接删数据，风险更高 |
| `chattr +i` 在 `/data/media` 的 FUSE 层不生效 | 已存在 | 新方案不依赖它作为唯一保障（内容已移走） |
| 恢复时 App 已重建同名目录 | 已处理 | 改名保留到 `.samnew`，不覆盖 |

## 10. 实施步骤

1. 改 `scripts/ad.sh`：`HOLD_SUFFIX` / `ad_exclude` / `block_ad` / `recovery_ad` / `run` / `list_ad` / manifest / `hold` 子命令
2. 去重 `ad_path`，处理 2 条通配符路径
3. 改 `webroot/index.html` + `webroot/js/main.js`
4. 本地 mock 测试：block→recovery 往返、老状态兼容、幂等、App 期间写入、exclude 跳过
5. 升版本 + changelog + 打包发布

## 11. 决策记录（2026-10-22 已确认并实施）

1. **`/data/system/ifw` 排除** —— 已从 `ad_path` 移除，并加进 `ad_exclude` 双保险
2. **通配符路径支持 glob 展开** —— 改为 `"${ad_path[@]}"` + case 分支显式展开（见第 12 节的认知修正）
3. **11 条 `shared_prefs/*.xml` 保留在屏蔽列表** —— 有了可逆方案后不必再删，改用改名保留屏蔽
4. **备份用 in-place rename** —— 零额外空间、瞬时、随原路径生命周期

## 12. 实施过程中发现并修掉的问题

原设计没预料到的坑，都是实测才发现的：

| 问题 | 现象 | 原因 | 修法 |
|---|---|---|---|
| 备份清单不更新 | 恢复后清单里仍残留一条记录 | `grep -vxF` 把最后一行也过滤掉时返回 1，`&& mv` 短路导致没写回 | 去掉 `&&` 链，无条件 `mv` |
| 边遍历边改清单 | 恢复时漏掉部分条目 | `recovery_ad` 内部会从清单删条目，而外层正在读同一个文件 | 遍历前先复制一份到临时文件 |
| 通配符误伤备份 | 二次 block 出现 `.samhold.samhold` | `res_*` 的 glob 展开会连带命中 `res_001.samhold`（`*` 匹配任意字符） | 新增 `is_hold_item()`，glob 展开时排除 `.samhold` / `.samhold.samnew` 结尾的项 |
| 数组展开拆词 | 含空格的路径会静默失效 | `for ad in ${ad_path[@]}` 未加引号，路径按空格拆成多个词 | 改为 `"${ad_path[@]}"`，含 `*` 的项由 case 分支显式 glob 展开 |
| list 解析源码过宽 | 影响范围列表里混进函数体行 | 原判断只要求「含引号」 | 收紧为「整行是双引号包裹的路径」且「以 / 开头」 |

### 关于通配符路径的认知修正

原文档说「2 条通配符路径从未生效」，**这个结论是错的**。
`for ad in ${ad_path[@]}` 未加引号时，shell 会对数组元素**再做一次路径名展开**，
所以 `res_*` 原本就会被展开成具体项，这些路径一直是生效的。

真正的问题是这个「隐式展开」同时带来拆词风险，因此改成
**加引号保完整性 + 显式处理 `*`**，两边都正确。
