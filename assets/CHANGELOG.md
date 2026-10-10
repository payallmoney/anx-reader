## 1.15.57
- Perf(import): Scheduler-level CPU split — the extraction isolate and the MD5 thread run at background scheduling priority (nice +10 via FFI), and the native SAF copy/MD5 channel moved off the Android main thread onto a background task queue at background priority. The UI threads always win core contention now; imports only consume leftover capacity. Verified mid-import: two tab switches completed in 185ms with the shelf rendering normally
- Perf(导入): 调度器级 CPU 分配——元数据提取 isolate 与 MD5 线程以后台优先级运行(FFI 设 nice +10),原生的 SAF 复制/MD5 通道也从 Android 主线程挪到后台任务队列并以后台优先级执行。UI 线程在核心竞争时永远优先,导入只消耗剩余算力。实测导入中两次 tab 切换仅 185ms,书架渲染正常

## 1.15.56
- Perf(import)!: Aggressive low-power mode while reading — imports detect an open reader and drop to a ~20% CPU duty cycle: the cover (the single most expensive per-book item: image extraction + disk write) is skipped entirely during reading, the inter-book yield grows to 150ms, and after the import finishes all skipped covers are backfilled at full speed automatically. Page turns stay smooth even on large imports; reading comfort no longer trades against import progress

- Perf(导入)!: 激进的阅读期低功耗模式——导入检测到正在看书即降到约 20% CPU 占空比:直接跳过封面(单本最贵的环节:图片解压+写盘),书本间隔拉大到 150 毫秒;导入完成后自动全速补齐所有跳过的封面。大库导入时翻页依旧顺滑,阅读舒适度不再与导入进度互相牺牲

## 1.15.55
- Fix(import): The resume dialog swapped the folder name and the remaining count — the generated l10n signature was (count, name) because the placeholders metadata was missing; explicit metadata now pins (name, count), also fixing the delete-folder confirmation which had the same swap

- Fix(导入): 恢复导入弹窗的文件夹名和剩余数量互换了——缺少 placeholders 元数据导致生成的文案参数序为(数量,名称);现已显式声明(名称,数量),同样问题的删除文件夹确认框一并修正

## 1.15.54
- Perf(import): Covers are now written to disk inside the extraction isolate — previously every book shipped a multi-megabyte base64 data URI across isolate boundaries and decoded it on the main thread; the isolate writes the cover file directly and only a KB-sized path crosses over, removing the last big per-book main-thread cost during imports

- Perf(导入): 封面改为在提取 isolate 内直接写盘——此前每本书都要跨 isolate 传输数 MB 的 base64 数据并在主线程解码,这是导入期间最后一笔大的逐本主线程开销;现在跨线程只传 KB 级路径

## 1.15.53
- Feat(import): The progress pill is visible on the reader page again — imports visibly continue while you read
- Perf(import): More CPU left for the UI — cover base64 decoding moved off the main thread (multi-MB strings decoded in an isolate), and the pause between books doubled to 40ms; the ANR "no response" popups during large imports came from per-book work hogging the main thread and are addressed by these two
- Fix(import): Removed the per-book "import success" toasts (single-file imports and batch imports alike) — only one notice when everything is done

- Feat(导入): 阅读页重新显示导入进度条——看书时能直接看到导入进展
- Perf(导入): 为界面留出更多 CPU——封面 base64 解码(数 MB 字符串)移入 isolate,书本间隔让出时间加倍至 40 毫秒;大库导入时的"失去响应"弹窗正来自这些逐本主线程操作
- Fix(导入): 移除逐本的"导入成功"提示(单本与批量 alike)——只有全部导入完成才提示一次

## 1.15.52
- Feat(bookshelf): Folder dialog actions are icons in the top-right corner — edit toggle, dissolve and delete-folder moved from the bottom text row into the title bar; the rename hint pencil is now a distinct icon

- Feat(书架): 文件夹弹窗的操作按钮改为右上角图标——编辑切换、解散、删除文件夹从底部文字行移入标题栏;重命名提示铅笔换为独立图标以示区分

## 1.15.51
- Feat(webdav): Downloads from the WebDAV browser now land in the library automatically — after downloading, each book is imported in place (no re-copy) and shelf folders are created per remote subfolder, mirroring folder imports; plain files under the sync root group under "WebDAV". Download-only: no sync state is touched, nothing is uploaded
- Feat(webdav): WebDAV 浏览器的下载现在自动入书库——下载完成后每本书原位导入(不重复复制),并按远端子目录创建书架分组(与文件夹导入一致);同步根目录下的散文件归入 "WebDAV" 根分组。纯下载行为:不触碰任何同步状态,绝不上传

## 1.15.50
- Feat(import): The shelf shows the new folder as soon as its first book lands (one early refresh), and stays untouched until the whole import finishes (final refresh) — nothing in between

- Feat(导入): 文件夹里第一本书落库后立即刷新一次(书架马上能看到新文件夹),此后直到导入全部完成期间书架保持静止(仅结束时最终刷新),中间不再有任何刷新

## 1.15.48 / 1.15.49
- Perf(import)!: Folder imports no longer compete with the UI for the main thread — each imported book used to trigger a full shelf rebuild (query + pinyin sort + grid rebuild with animations), which on a 630-book library froze every animation and broke open dialogs (cells floating above the dialog scrim); the shelf now stays completely untouched during the import and is rebuilt once at the end, and the import loop yields the main thread 15ms between books
- Perf(导入)!: 文件夹导入不再与界面抢主线程——此前每导入一本就全量重建书架(查询+拼音排序+网格动画重建),630 本的库会让所有动画冻住、打开的弹窗出现格子浮层的错乱;现在导入期间书架完全静止,结束时一次性重建,并且每本之间主动让出主线程 15 毫秒

## 1.15.47
- Refactor(import)!: One pipeline iteration per book — copy, import and the resume checkpoint complete together, and the sequence number is persisted immediately; a resume therefore never repeats work. A staged copy left by an interrupted run is reused when its file size matches (corrupt partial copies are detected and re-copied); the separate copy-then-import phases are gone
- Refactor(导入)!: 每本书一个流水线迭代——复制、导入、断点记录一次完成,序号立刻落盘;恢复导入绝不重复已做的工作。上次中断留下的已复制文件在校验大小一致后直接复用(不完整的部分副本会被识别并重新复制);独立的"先复制后导入"两阶段已移除

## 1.15.46
- Feat(import): Resuming an interrupted import now asks first — on the next launch a dialog names the interrupted folder and the remaining file count; Continue resumes from the exact breakpoint, Cancel drops the task (already-imported books stay; re-importing the folder later picks up the rest)

- Feat(导入): 恢复被中断的导入前先询问用户——启动时弹窗显示被中断的文件夹名和剩余文件数;"继续"从精确断点续导,"取消"丢弃任务(已导入的书保留,之后重新导入同一文件夹可续齐)

## 1.15.45
- Fix(tts): Screen-off narration no longer dies mid-chapter after a long while — two root causes: (1) the online-TTS buffer deduplicated fallback sentences by text hash, so repeated sentence patterns starved the buffer and narration silently stopped; fallback sentences now carry unique position cfis. (2) When the network drops during screen-off (WiFi doze), failed Azure segments were marked silent and the player burned through the chapter in milliseconds, ending narration; it now backs off and waits for the network instead. A playback watchdog unsticks a dead audio session after 60s
- Feat(tts): Waking the screen now syncs the reader to the narrated position — the Dart fallback narrates without touching the frozen webview, so the visible page stayed on the chapter's first page; on resume the reader jumps to the narration position and paused narration resumes

- Fix(朗读): 息屏朗读长时间后不再在章节中间停住——两个根因:(1) 在线 TTS 缓冲用文本哈希去重兜底句,重复句式会饿死缓冲导致朗读无声停止;现给兜底句分配唯一位置 cfi。(2) 息屏时网络断开(WiFi Doze),Azure 合成失败的段落被标为静音并被瞬间消费,几毫秒烧完整章后朗读结束;现在改为退避等待网络恢复。另加 60 秒播放看门狗解开死锁的音频会话
- Feat(朗读): 亮屏后阅读页自动同步到朗读位置——Dart 兜底朗读时冻结的 WebView 不会动,屏幕点亮时页面还停在熄屏时的章节第一页;现在亮屏即跳转到朗读实际位置,暂停态自动恢复朗读

## 1.15.43
- Feat(import)!: Imports now continue while you read — epub metadata (title/author/cover) is extracted in a background isolate in pure Dart (no webview, no main-thread contention), making imports ~15× faster (~0.2s per book vs ~2.5s) AND removing the need to pause during reading; the headless-webview path remains only as fallback for non-epub/unparseable files, and it still defers to the reader
- Fix(import): A resumed import's progress pill now shows the true position (continues at e.g. 45/60) instead of restarting from 1
- Fix(导入)!: 看书时导入继续进行——epub 元数据(标题/作者/封面)改为纯 Dart 后台 isolate 提取(无 WebView、不抢主线程),导入提速约 15 倍(每本约 0.2 秒)且看书时无需暂停;无头 WebView 仅保留为非 epub/解析失败时的兜底,且仍为阅读让路
- Fix(导入): 续传时进度条显示真实位置(如从 45/60 继续),不再从 1 重新计数

## 1.15.41
- Feat(reading)!: Reading no longer stutters during folder imports — the reader announces its lifecycle to the import system, which parks metadata extraction while a book is open and resumes when you leave; the progress pill also hides inside the reader, and shelf refreshes are suppressed during reading
- Feat(阅读)!: 导入文件夹时看书不再卡顿——阅读页把自己的生命周期告知导入系统:看书期间元数据提取自动暂停,退出书后无缝继续;阅读页内不再显示进度悬浮条,阅读期间书架刷新也被抑制

## 1.15.40
- Feat(import): Interrupted folder imports now survive an app restart — the task (folder, file list, progress) is persisted while importing, and on the next launch the floating pill reappears and the remaining files continue automatically; a resume also reconciles against the library first so already-imported books are skipped without re-processing
- Fix(import): Book metadata extraction is now serialized with a global lock — the import temp file is a singleton, so overlapping extractions (possible when resuming over an existing library) overwrote each other's URL and stalled the queue

- Feat(导入): 导入中断后重启应用可自动续传——导入期间任务(文件夹、文件清单、进度)持续落盘,下次启动悬浮进度条自动恢复,剩余文件继续导入;续导前先与书库对账,已入库的书直接跳过不再处理
- Fix(导入): 书籍元数据提取加全局串行锁——导入临时文件是单例,重叠的提取(续导叠加已有书库时可能发生)会互相覆盖地址导致队列停滞

## 1.15.37
- Fix(import): Imports no longer freeze the app — the parallel file copy saturated IO threads on real devices (slower than serial, not faster) and the per-book shelf refresh rebuilt the whole grid every few books; copying is sequential again, shelf refreshes are debounced to at most one per 5 seconds, and the progress pill throttles its updates (300ms) behind a repaint boundary
- Fix(导入): 导入不再卡死应用——并行文件复制在真机上反而拖慢 IO(串行更快),且逐本刷新书架每几本就重建整个网格;已改回串行复制,书架刷新去抖为至多每 5 秒一次,进度胶囊更新节流(300 毫秒)并加重绘隔离

## 1.15.36
- Feat(bookshelf)!: Long-press any shelf cell to enter multi-select with it pre-selected — the previous behaviour (long-press started a drag that showed a book sheet and looked like "dragging, not selecting") is gone: drag-to-reorder was a no-op anyway and its gesture shadowed multi-select; taps still open books/folders, and the top-bar multi-select button still works

- Feat(书架)!: 长按书架任意格子直接进入多选并选中该格——此前长按触发的是拖动(看起来"能拖不能选");拖动重排本就是空操作且其手势挡住了多选,现已禁用;单击仍是打开书/文件夹,顶栏多选按钮同样可用

## 1.15.35
- Feat(bookshelf): "Delete folder" action in the folder dialog — removes the folder (and its subfolders) after an explicit confirmation; its books return to the shelf top level, book files are never touched

- Feat(书架): 文件夹弹窗新增"删除文件夹"——确认后移除文件夹(含子文件夹),其中的书全部移回书架顶层,书籍文件绝不删除

## 1.15.34
- Feat(import): Non-blocking import progress pill replaces the full-screen loading dialog — a small floating capsule at the top shows live "Importing books n/N", tap to expand Pause / Resume / Cancel; the app (including reading) stays fully usable during imports, and a cancelled import keeps everything already saved (re-import the folder to continue)
- Perf(import): The copy phase now runs 3 files in parallel and the import loop polls a shared progress service, roughly 25% faster end-to-end on a 60-book folder
- Fix(导入)!: 全屏加载框替换为不阻塞的悬浮进度胶囊——顶部小条实时显示"正在导入书籍 n/N",点开可暂停/恢复/取消;导入期间 app(包括阅读)完全可用,取消导入会保留已导入的书(重新导入该文件夹即可续传)
- Perf(导入): 复制阶段改为 3 文件并行,导入循环共用进度服务;60 本实测端到端提速约 25%

## 1.15.31 / 1.15.32
- Fix(import)!: Folder import is now two-phase exactly as requested — first create the shelf folder and copy every file into app storage, then import them one by one; the folder exists from the very start and can only ever appear once, no more one-folder-per-file flashes that only corrected themselves after an app restart
- Fix(import): The loading dialog now reports live progress (n books saved) instead of freezing on "copying", and the shelf refreshes as books land inside the folder
- Fix(import): Covers without inline base64 data no longer throw during import (books with external/broken covers now save cleanly instead of erroring)

- Fix(导入)!: 文件夹导入改为按需求的两阶段——先建书架文件夹并把所有文件复制进应用存储,再逐本导入;文件夹从第一步起就存在且只会出现一个,不再出现"每个文件闪一个目录、重启后才恢复正常"的现象
- Fix(导入): 加载提示现在实时显示进度(已导入 N 本),不再是卡住的"正在复制";书落入文件夹时书架同步刷新
- Fix(导入): 无内嵌 base64 数据的封面导入时不再抛错(封面缺失/外链的书现在能正常入库)

## 1.15.30
- Fix(import)!: Folder imports create the shelf folder BEFORE copying and every imported book record is born with its group membership; updating an existing record through a re-import no longer resets its folder (saveBook never passed group_id, so a late webview metadata callback after the grouping pass silently moved books back to the shelf root — the folder stayed empty and invisible, which only reproduced on slow real devices)
- Fix(书架): 文件夹导入改为先建书架文件夹、每本书落库即带分组;重新导入更新旧记录不再把分组重置回书架顶层(saveBook 此前从不写 group_id,webview 元数据回调晚于分组步骤时会把书悄悄移出文件夹——文件夹因此空了不显示,该竞争只在真机上复现)

## 1.15.29
- Fix(import): Importing a folder again always (re)creates the shelf folder and assigns the imported books into it — books already sitting in another live folder were mistaken for manually organised and skipped, so re-imports stopped creating the folder; this also self-heals shelves where older buggy imports left books in junk-named folders

- Fix(导入): 重新导入文件夹总会(重新)创建书架文件夹并把导入的书放进去——之前已在其他活文件夹里的书被误判为"手动整理过"而跳过,导致导入不再建目录;对旧版本错误导入留下的垃圾名文件夹也能通过重新导入自愈

## 1.15.28
- Fix(import): Imported folders are named after the picked folder again — v1.15.24 preferred deriving the name from the SAF document id, which some third-party file providers turn into junk like "root"; the folder's display name is now authoritative and the id is only a fallback for storage volume labels

- Fix(导入): 导入的文件夹恢复使用所选文件夹的真实名称——v1.15.24 起优先从 SAF document id 推导名称,部分第三方文件管理器会给出 "root" 之类的垃圾值;现在以显示名称为准,document id 仅作为存储卷标名的兜底

## 1.15.27
- Fix(bookshelf): Entering the bookshelf no longer spins repeatedly — the folder list was read as a side watch, so the shelf built twice per entry (once with no folders, then again when the folder query landed) and every reload flashed the loading spinner; the list now awaits folders in a single build and reloads keep the shelf on screen
- Fix(bookshelf): Loose books no longer appear twice — the built-in pseudo "Root" group was treated as a shelf folder and wrapped every ungrouped book into an extra folder cell
- Perf(startup): The one-time folder migration loads live groups in one query and applies its updates in a single transaction; it exits instantly when nothing matches

- Fix(书架): 进入书架不再反复转圈——文件夹列表此前作为旁路监听,书架每次进入都构建两遍(先无文件夹、分组查询返回后重来),且每次重载都闪加载圈;现在单次构建内等待分组数据,重载时保留当前书架画面
- Fix(书架): 散书不再显示两遍——内置的 "Root" 伪分组被当成了书架文件夹,把所有未分组书额外包进了一个文件夹格子
- Perf(启动): 一次性文件夹迁移改为单查询活分组+事务批量更新,无可迁移数据时瞬时跳过

## 1.15.26
- Fix(tts): Screen-off narration no longer jumps back to an earlier chapter — the fallback used a tolerant text match over the whole book, so a chapter heading could match its own duplicate in the table of contents (or any repeated phrase) and narration resumed chapters behind. Positioning now trusts the continuously-synced sentence index first, matches text only locally around the cursor, and cursor syncing never wraps back to the book start
- Fix(书架): 息屏续读不再跳回前面的章节——兜底定位此前对全书做宽容文本匹配,章节标题会命中目录页里的同名条目(或任何重复短语),导致从几章之前的位置续读。现在优先使用持续同步的句子索引,文本匹配只在游标附近局部进行,游标同步也不再回卷到书首

## 1.15.25
- Feat(bookshelf)!: Shelf folders are now purely virtual and freely editable — they no longer mirror the on-disk storage layout. Nested subfolders, per-folder rename, move any book into any folder (or out to the shelf), dissolve; nothing ever touches the book files
- Feat(bookshelf): Folder dialogs gained a subfolder chip row with inline creation; edit mode adds a move-to-folder picker (shelf root / any folder indented by depth / create new subfolder); dissolving a folder handles its subfolders recursively
- Fix(bookshelf): Single-member folders render as folders (they used to collapse into plain book covers); folders emptied by deletions stay visible as pass-through containers while deeper books exist
- Fix(import): Re-importing a folder no longer pulls books out of folders you placed them in manually; the storage-layout healing from 1.15.23 became a one-time migration so it can never override manual organisation

- Feat(书架)!: 书架文件夹改为纯虚拟、可自由整理——不再与磁盘存储目录绑定。支持多级子文件夹、文件夹重命名、把任意书移动到任意文件夹(或移出到书架)、解散;所有操作都不会碰书文件
- Feat(书架): 文件夹弹窗新增子文件夹 chips 行,可直接新建;编辑模式增加"移动到文件夹"选择器(书架顶层/按层级缩进的任意文件夹/新建子文件夹);解散文件夹会递归处理子文件夹
- Fix(书架): 只有单本书的文件夹现在显示为文件夹(之前会塌缩成普通封面);被删空的文件夹只要深层还有书就保持可见(透传容器)
- Fix(导入): 重新导入文件夹不再把手动整理过的书拽回默认文件夹;1.15.23 的存储布局自愈改为一次性迁移,绝不会覆盖手动整理结果

## 1.15.24
- Fix(import): Folder-import grouping is now bulletproof: it no longer aborts when the import outlives the page (large folders, app switch, activity recreation), empty folder names fall back to "imported" instead of silently skipping, and every step is written to anx_reader.log for diagnosis
- Fix(import): The all-files fast path derives the folder name from the SAF document id like the fallback path (volume-label names no longer leak as shelf folder names)

- Fix(导入): 文件夹导入的分组逻辑全面加固:导入耗时超过页面生命周期(大文件夹、切后台、Activity 重建)不再中断分组;文件夹名为空时兜底为 "imported" 而不是静默跳过;每一步都写入 anx_reader.log 便于排查
- Fix(导入): "所有文件访问"快速路径同样从 SAF document id 推导文件夹名,卷标名不再泄漏为书架文件夹名

## 1.15.23
- Fix(bookshelf): Shelf multi-select actually works now — selection taps used to fall straight through the cell (hit-test transparent wrapper), and books living inside shelf folders were not selectable at all; both fixed and folder cells can be batch-deleted as a whole
- Fix(import): Shelf folders are now reconciled from the storage layout on startup and after every folder import, so books left ungrouped by older versions (or a slow/failed grouping step) appear in their folder without a re-import; manual folder assignments are respected

- Fix(书架): 书架多选删除真正可用了——此前选择点击会直接穿透格子(命中测试透明),且文件夹内的书完全无法选中;两者已修复,文件夹格子可整体批量删除
- Fix(导入): 启动时和每次文件夹导入后都会按存储布局对账书架分组,旧版本遗留的未分组书籍(或分组步骤失败的情况)无需重新导入即可归位;手动整理过的分组不受影响

## 1.15.18
- Feat!: Rebranded application id to payallmoney.github.com — installs alongside the original app with its own signing key and an "oyx" wordmark on the launcher icons
- Feat(import): Folder import with recursive subdirectory scanning; books are stored under a subdirectory named after the picked folder and grouped into a shelf folder of the same name, original file names preserved (no numeric prefixes), idempotent re-imports
- Feat(import): On Android, folder picking bypasses SAF uri-grant pitfalls by using the all-files fast path, fixing silently empty imports
- Feat(import): Deleting books only removes them from the library — book files are never deleted; shelf multi-select mode with batch delete
- Feat(storage): Storage root defaults to the user-visible /storage/emulated/0/AnxReader (grantable in settings) with automatic migration from the app-private folder, custom path supported
- Feat(webdav): Directory-based sync — in-place books upload under library/<folder>/, downloads restore into a configurable download directory, and a new WebDAV file browser lets you pick individual files to download
- Fix(tts): Narration no longer stalls at chapter boundaries after screen-off — the chain is completion-driven with a pure-Dart epub fallback that keeps reading with the WebView completely frozen, resuming at the exact sentence (never from chapter one) via a continuously synced cursor
- Fix(tts): The online TTS chain (Azure etc.) is fully covered by the same screen-off recovery; a 30s stall watchdog auto-resumes narration whatever the failure mode
- Perf(import): MD5 computed on a background isolate (or during the streaming copy), no longer blocking the import progress
- Fix(reader): Dark reading themes no longer show bright scroll-bar edges on the right/bottom — the WebView chrome follows the reading background and native scrollbars are disabled

- Feat!: 应用 ID 更换为 payallmoney.github.com——与原版应用并存安装,独立签名,启动器图标带 "oyx" 小字标识
- Feat(导入): 文件夹导入支持递归子目录;书籍存放在与所选文件夹同名的子目录并在书架自动创建同名分组,保留原文件名(无数字前缀),重复导入幂等
- Feat(导入): Android 文件夹选择改用"所有文件访问"快速路径,绕开 SAF 授权陷阱,修复静默导入为空的问题
- Feat(导入): 删除书籍仅移出书库,绝不删除书文件;书架支持多选批量删除
- Feat(存储): 存储根目录默认为用户可见的 /storage/emulated/0/AnxReader(设置中授权),自动从应用私有目录迁移,支持自定义路径
- Feat(同步): WebDAV 目录化管理——原位书籍按 library/<目录>/ 结构上传,下载恢复到可配置的下载目录,新增 WebDAV 文件浏览器可勾选单个文件下载
- Fix(朗读): 息屏后跨章不再停住——朗读链改为完成事件驱动,WebView 完全冻结时由纯 Dart 的 epub 解析兜底续读;通过持续同步的游标从准确的句子位置续读(绝不从第一章重来)
- Fix(朗读): 在线 TTS(Azure 等)链路同样具备息屏续读能力;30 秒停顿看门狗在任何故障模式下自动恢复朗读
- Perf(导入): MD5 改为后台 Isolate(或在流式复制时一并计算),不再阻塞导入进度
- Fix(阅读): 深色阅读主题下右侧/底部不再出现亮色滚动条边缘——WebView 底色跟随阅读背景并禁用原生滚动条

## 1.15.0
- Ci(android): Play Store beta CI now completes Closed testing (alpha) and Open testing (beta) tracks so testers can download without a Console roll-out
- Ci(android): Play Store alpha uploads to the internal track now publish as completed so testers can download without a Console roll-out
- Fix(sync): Reject WebDAV database upload when the local library has no non-deleted books, to avoid wiping the cloud library with an empty DB (#911, #898 mitigation)
- Feat(notes): Export/import book notes as JSON with book fingerprint (md5/title/author) for per-book migration across devices (#898, #911 escape hatch)
- Fix(webdav): Follow 301/307/308 redirects (vendored webdav_client) so AList-style redirect strategies work (#345)
- Fix(android): Optional setting to trust user-installed / custom CA certificates for HTTPS WebDAV (e.g. private Nextcloud) (#719)
- Feat(sync): WebDAV URL hint — fill a writable directory; the app creates `anx/` under it
- Feat(android): Long-press expands CJK selection to a word (Intl.Segmenter); selection handles remain freely draggable
- Fix(reader): Honor writing-direction setting for EPUBs that set writing-mode on body (e.g. vertical Japanese books) (#867)
- Fix(log): Silence Chromium iframe sandbox WebView warning that already had an ignore entry but failed exact match due to trailing period (#877)
- Ci: Upgrade lock-threads to v6 and use github.token so lock-closed-issues stops failing daily on long GITHUB_TOKEN secrets
- Feat(search): Add in-app search results with configurable search engine and display modes (#894)
- Feat(ai): Add configurable delay threshold for auto-summary when reopening a book (#922)
- Feat(ai): Make custom user prompts available in the Home AI tab for parity with reader AI (#853)
- Fix(bookshelf): Show book file format in detail metadata so users can see the extension inside the app (#910)
- Feat(network): Add global HTTP proxy support in advanced settings (#838) Thanks @dddXzz
- Feat(network): Add HTTP proxy connectivity test feature (#838) Thanks @dddXzz
- Fix(reader): Fix Android selection auto-page turn — continuous turns and missed turns when dragging across pages (#875) Thanks @addtion99
- Fix(l10n): Update Russian translation (#874) Thanks @Xapitonov
- Fix(ai): Avoid native WebView2 crash when running book content search on Windows (#978) Thanks @bazzdug-arch
- Perf(reader): Reduce Android reading-page scroll jank by deferring relocate during scroll (#914) Thanks @dddXzz
- Fix(reader): Restore reader keyboard focus after clearing text selection / closing context menu (#967, #966) Thanks @zyx-31415
- Fix(reader): Open selection menu on single-word long-press on Android (#990, #968, #900)
- Fix(sync): Strip special characters (e.g. # @ $ %) from file names on import so WebDAV servers like Jianguoyun accept uploads (#989)
- Feat(appearance): Disable open-book animation, page transitions, and dialog motion when e-ink mode is on (#986)
- Fix(bookshelf): Make group rename more obvious with an edit icon (#972)
- Fix(ai): Preserve Gemini thought_signature across tool-call round-trips so thinking models work with tools (#977)
- Fix(reader): Page-turn keys clear selection and turn pages instead of panning while text is selected (#966)
- Fix(ai): Null-safe custom provider config parsing and clearer errors when required fields or response shape are invalid (#868)
- Fix(ai): Quick prompt chips insert into the composer for editing; long-press still sends immediately (#969)
- Feat(linux): Add Linux AppImage and tar.gz packaging via CEF (#952)
- Fix(ai): Make the Add Prompt button in AI settings full-width to match the surrounding rows
- Fix(ai): Fix AI settings showing a grey error screen on fresh installs and provider edits failing to save, by restoring generated AiProvider JSON serialization with lenient converters
- Chore(android): Target Android 16 (API 36) and upgrade to Google Play Billing Library 8 to meet Google Play requirements

- Ci(android): Play 商店 beta CI 现会将版本同步发布到 Closed testing（alpha）与 Open testing（beta）并设为 completed，测试者无需在 Console 手动发布即可下载
- Ci(android): Play 商店 alpha 上传至 internal 轨道时自动设为 completed，测试者无需在 Console 手动发布即可下载
- Fix(sync): 本地书库无未删除书籍时拒绝上传 WebDAV 数据库，避免用空库覆盖云端 (#911, #898 缓解)
- Feat(notes): 支持按书导出/导入笔记 JSON（含 md5/书名/作者指纹），便于跨设备迁移批注 (#898, #911 逃生舱)
- Fix(webdav): 跟随 301/307/308 重定向（vendored webdav_client），兼容 AList 等 302 策略 (#345)
- Fix(android): 新增可选设置以信任用户安装/自定义 CA 证书，便于私有 Nextcloud 等 HTTPS WebDAV (#719)
- Feat(sync): WebDAV URL 提示——填写可写入目录，应用会在其下创建 `anx/`

- Feat(android): 长按单字 CJK 选区通过 Intl.Segmenter 扩展为词语，仍可自由拖动手柄调整选区
- Fix(reader): 修复部分 EPUB（如在 body 上设置竖排 writing-mode）忽略写作方向设置的问题 (#867)
- Fix(log): 修复因句末句点导致精确匹配失败、未能屏蔽 Chromium iframe sandbox WebView 警告的问题 (#877)
- Ci: 升级 lock-threads 至 v6 并改用 github.token，避免 lock-closed-issues 因过长 GITHUB_TOKEN 每日失败
- Feat(search): 支持应用内搜索结果显示，可配置搜索引擎和显示方式 (#894)
- Feat(ai): 新增自动摘要延迟阈值配置，可控制重新打开书籍时的摘要触发时机 (#922)
- Feat(ai): 让自定义用户提示词在首页 AI 标签页中可用，并与阅读器 AI 保持一致 (#853)
- Fix(bookshelf): 在书籍详情元数据中显示文件格式，方便用户在应用内查看扩展名 (#910)
- Feat(network): 新增全局 HTTP 代理支持，可在高级设置中配置代理服务器地址和端口 (#838) 感谢 @dddXzz
- Feat(network): 新增代理连接测试功能 (#838) 感谢 @dddXzz
- Fix(reader): 修复 Android 选区跨页自动翻页的连续翻页与漏翻问题 (#875) 感谢 @addtion99
- Fix(l10n): 更新俄语翻译 (#874) 感谢 @Xapitonov
- Fix(ai): 修复 Windows 上书籍内容搜索触发原生 WebView2 崩溃的问题 (#978) 感谢 @bazzdug-arch
- Perf(reader): 优化 Android 阅读页滚动卡顿，滚动期间推迟 relocate (#914) 感谢 @dddXzz
- Fix(reader): 修复清除选区/关闭上下文菜单后阅读器键盘焦点未恢复的问题 (#967, #966) 感谢 @zyx-31415
- Fix(reader): 修复 Android 长按选中单字不弹出菜单的问题 (#990, #968, #900)
- Fix(sync): 导入时移除文件名中的特殊字符（如 # @ $ %），避免坚果云等 WebDAV 拒绝上传 (#989)
- Feat(appearance): 开启墨水屏模式时关闭开书动画、页面转场与弹窗动画 (#986)
- Fix(bookshelf): 分组重命名入口增加编辑图标，更加明显 (#972)
- Fix(ai): 修复 Gemini 工具调用时缺失 thought_signature 导致思考模型报错的问题 (#977)
- Fix(reader): 选中文本时方向键/翻页键先清除选区再翻页，避免页面平移 (#966)
- Fix(ai): 自定义供应商配置解析更空安全，并在必填项或响应格式异常时给出明确错误 (#868)
- Fix(ai): 快捷提示词芯片点击写入输入框以便编辑，长按仍可立即发送 (#969)
- Feat(linux): 新增 Linux AppImage 与 tar.gz 打包支持（基于 CEF）(#952)
- Fix(ai): AI 设置中“添加提示词”按钮改为占满整行，与上下设置项对齐
- Fix(ai): 修复全新安装时 AI 设置页灰屏、供应商增删改无法保存的问题（恢复 AiProvider 生成式 JSON 序列化并保留宽松解析）
- Chore(android): 目标 SDK 升级到 Android 16（API 36），并升级到 Google Play Billing Library 8，满足 Google Play 上架要求

## 1.14.0
- Fix(translate): Remove legacy Microsoft reverse-engineered translation service and migrate saved full-text translation preference to Microsoft Azure API
- Fix(l10n): Remove legacy Microsoft translation localization entries
- Feat(ai): Support separate AI reasoning content with lightweight collapsible thinking UI in chat and stream views (#787)
- Feat(reader): Add background image fit mode setting with cover and stretch options
- Feat(appearance): Add setting to toggle action button labels visibility in selection context menu
- Feat(reader): Add background image blur and opacity controls in reading settings (#753)
- Feat(tts): Add Narrator option to text selection toolbar to start TTS from selected text (#794) Thanks @deskangel
- Feat(tts): Add click to pause/resume TTS playback on currently reading text (#794) Thanks @deskangel
- Feat(tts): Add floating action button in reader for quick TTS controls (previous, pause/resume, next, stop) (#723)
- Feat(reader): Add Ctrl+[ and Ctrl+] page turning shortcuts on macOS, support Logitech Options+ mouse button mapping (#794) Thanks @deskangel
- Feat(ai): Add global AI RPM rate limiting in AI service layer
- Feat(ai): Add AI Provider Configuration Center with support for OpenAI-compatible, Claude, and Gemini protocols
- Feat(ai): Support multiple API keys per provider with round-robin rotation
- Feat(ai): Add provider-level reasoning_effort configuration with auto mode and advanced settings entry
- Feat(ai): Add provider test connection with streaming preview
- Feat(ai): Add AI chat display mode settings with adaptive, split, and popup options
- Feat(ai): Add resizable AI panel with drag to resize, sizes persisted
- Feat(ai): Add AI panel position settings (bottom/right) for non-popup modes
- Feat(ai): Add font size setting for AI chat via three-dot menu
- Feat(ai): Add quick model switcher in AI chat input bar (tune icon button)
- Feat(ai): Add model picker in provider detail page with showMenu dropdown after fetching
- Fix(ui): Fix context menu action buttons layout and icon color issues when labels are hidden
- Fix(reader): Fix background image effects not applying and switch reader background fill mode to cover (#753)
- Fix(reader): Fix RangeError crash when read theme color is null/invalid (#759)
- Fix(tts): Fix TTS type selection having no effect when changed in reading interface (#794) Thanks @deskangel
- Fix(tts): Fix incorrect reading position after modifying pitch or rate (#794) Thanks @deskangel
- Fix(tts): Fix crash when SystemTts speak() receives null text from WebView
- Fix(ai): Fix unable to use AI for full-text translation
- Fix(ai): Fix test connection using default provider instead of current provider
- Fix(ai): Fix AI crash prevention by adding guards for null webViewEnvironment on Windows
- Fix(ai): Fix type cast error when using Gemini AI with tools (#747)
- Fix(reader): Desktop resource lifecycle, WebView stability, and scroll UX optimization (#790) Thanks @yi124773651
- Fix(reader): Fix window close cleanup to properly stop server, dispose WebView2, close database, and destroy window
- Fix(reader): Add scroll debounce mechanism for smoother page turning experience
- Fix(reader): Fix image saving permission issue on Android 10+ devices by removing unnecessary storage permission requests (#793)
- Fix(reader): Disable WebView2 right-click context menu (back, reload, save as, print) on Windows (#746)
- Feat(tts): Add adjustable TTS speed, pitch, and volume settings with slider controls
- Feat(tts): Add system TTS engine selection with dropdown picker in TTS settings
- Feat(tts): Add TTS voice selection with language filtering based on device locale
- Feat(reader): Add long press to select text in EPUB reader for highlighting and note-taking
- Fix(reader): Fix text selection not working properly on Android devices
- Fix(reader): Fix crash when opening corrupted EPUB files with invalid metadata
- Feat(settings): Add reading theme customization with custom background colors and text colors
- Feat(settings): Add font size and line height adjustment in reading settings
- Fix(settings): Fix settings not persisting after app restart on iOS devices
- Feat(sync): Add WebDAV sync support for reading progress and bookmarks
- Fix(sync): Fix sync conflicts when multiple devices modify the same book
- Feat(import): Add support for importing CBZ comic book archives
- Fix(import): Fix PDF import failing for files with special characters in filename
- Feat(export): Add highlight and note export to Markdown format
- Fix(ui): Fix dark mode colors not applying correctly in some settings screens
- Feat(search): Add full-text search within EPUB books with result highlighting
- Fix(search): Fix search results not updating when switching between books
- Feat(collections): Add custom collections with drag-and-drop book organization
- Fix(collections): Fix collection order resetting after app update
- Feat(stats): Add reading statistics dashboard with daily/weekly/monthly views
- Fix(stats): Fix reading time calculation including background time on Android
- Feat(backup): Add automatic backup scheduling with configurable intervals
- Fix(backup): Fix backup file corruption when backup is interrupted
- Feat(ui): Add smooth page turn animations with customizable transition styles
- Fix(ui): Fix flickering when turning pages in fast scrolling mode
- Feat(accessibility): Add screen reader support for all major UI elements
- Fix(accessibility): Fix focus traversal order in settings menus
- Feat(i18n): Add Turkish, Romanian, and Ukrainian translations
- Fix(i18n): Fix missing translations for AI-related settings in all languages
- Feat(developer): Add debug logging toggle in advanced settings
- Fix(developer): Fix crash reports not including device information on Android 14+
