/*
 *  yyds.dylib — 腾讯 TSS 游戏安全模块 本地检测屏蔽器
 *  基于 IDA 逆向分析结果，Hook TSS SDK 全部核心检测函数
 *  版本: 1.0.0
 *  目标: iOS ARM64 (iPhone)
 */

#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/proc_info.h>
#import <sys/param.h>
#import <sys/mount.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <notify.h>
#import <pthread.h>
#import <signal.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <fcntl.h>
#import <errno.h>
#import <dirent.h>
#import <spawn.h>

// ============================================================
//  ██╗   ██╗██╗   ██╗██████╗ ███████╗
//  ╚██╗ ██╔╝╚██╗ ██╔╝██╔══██╗██╔════╝
//   ╚████╔╝  ╚████╔╝ ██║  ██║███████╗
//    ╚██╔╝    ╚██╔╝  ██║  ██║╚════██║
//     ██║      ██║   ██████╔╝███████║
//     ╚═╝      ╚═╝   ╚═════╝ ╚══════╝
// ============================================================

// ---------- 全局配置 ----------
static const char *LOG_PATH      = "/var/mobile/Documents/yyds_log.txt";
static const char *CONFIG_PATH   = "/var/mobile/Documents/yyds_config.txt";
static const char *NOTIFY_NAME   = "com.yyds.bypass.config_changed";

static volatile int  g_shield_enabled  = 1;   // 默认启用屏蔽
static volatile int  g_monitor_enabled = 1;   // 默认启用监控
static volatile int  g_should_exit     = 0;   // 退出标志
static pthread_mutex_t g_log_mutex     = PTHREAD_MUTEX_INITIALIZER;

// 存储原始函数指针
static int    (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int    (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int    (*orig_proc_regionfilename)(int, uint64_t, void *, uint32_t);
static kern_return_t (*orig_mach_vm_region)(vm_map_t, mach_vm_offset_t *,
                            mach_vm_size_t *, natural_t *, vm_region_info_t,
                            mach_msg_type_number_t *, mach_port_t *);
static kern_return_t (*orig_vm_region_64)(vm_map_t, vm_address_t *,
                            vm_size_t *, vm_region_flavor_t, vm_region_info_t,
                            mach_msg_type_number_t *, mach_port_t *);
static uint32_t (*orig__dyld_image_count)(void);
static const char *(*orig__dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig__dyld_get_image_header)(uint32_t);
static int (*orig_dladdr)(const void *, Dl_info *);
static int (*orig_ptrace)(int, pid_t, caddr_t, int);
static kern_return_t (*orig_task_for_pid)(mach_port_t, pid_t, mach_port_t *);
static pid_t  (*orig_getpid)(void);
static pid_t  (*orig_fork)(void);

// 记录自身模块信息
static const char       *g_self_path   = NULL;
static const void       *g_self_base   = NULL;
static uint32_t          g_self_index  = 0xFFFFFFFF;
static char             *g_self_name   = NULL;

// ========== 监控日志系统 ==========

static const char *level_str(int lvl) {
    switch (lvl) {
        case 0: return "INFO";
        case 1: return "WARN";
        case 2: return "HOOK";
        case 3: return "ERROR";
        default: return "DEBUG";
    }
}

static void yyds_log(int level, const char *tag, const char *fmt, ...) {
    if (!g_monitor_enabled) return;
    pthread_mutex_lock(&g_log_mutex);
    FILE *fp = fopen(LOG_PATH, "ab");
    if (fp) {
        time_t now = time(NULL);
        struct tm *t = localtime(&now);
        char timebuf[32];
        strftime(timebuf, sizeof(timebuf), "%m-%d %H:%M:%S", t);
        fprintf(fp, "[%s][%s][%s] ", timebuf, level_str(level), tag);

        va_list args;
        va_start(args, fmt);
        vfprintf(fp, fmt, args);
        va_end(args);

        fprintf(fp, "\n");
        fclose(fp);
    }
    pthread_mutex_unlock(&g_log_mutex);
}

#define LOGI(tag, fmt, ...) yyds_log(0, tag, fmt, ##__VA_ARGS__)
#define LOGW(tag, fmt, ...) yyds_log(1, tag, fmt, ##__VA_ARGS__)
#define LOGH(tag, fmt, ...) yyds_log(2, tag, fmt, ##__VA_ARGS__)
#define LOGE(tag, fmt, ...) yyds_log(3, tag, fmt, ##__VA_ARGS__)

// ========== 配置读取 ==========

static void yyds_read_config(void) {
    int fd = open(CONFIG_PATH, O_RDONLY);
    if (fd < 0) return;

    char buf[256] = {0};
    read(fd, buf, sizeof(buf) - 1);
    close(fd);

    if (strstr(buf, "shield=0"))  g_shield_enabled  = 0;
    if (strstr(buf, "shield=1"))  g_shield_enabled  = 1;
    if (strstr(buf, "monitor=0")) g_monitor_enabled = 0;
    if (strstr(buf, "monitor=1")) g_monitor_enabled = 1;
    if (strstr(buf, "exit=1"))    g_should_exit     = 1;
}

static void yyds_write_config(const char *cfg) {
    int fd = open(CONFIG_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, cfg, strlen(cfg));
        close(fd);
    }
    // 发送通知
    notify_post(NOTIFY_NAME);
}

// ========== 配置变更通知回调 ==========

static int g_notify_token = -1;
static void yyds_config_changed(void *arg) {
    yyds_read_config();
    LOGI("CONFIG", "配置已更新: shield=%d monitor=%d exit=%d",
         g_shield_enabled, g_monitor_enabled, g_should_exit);
}

// ========== 初始化 ==========

static void __attribute__((constructor)) yyds_init(void) {
    // 清空旧日志,记录启动
    unlink(LOG_PATH);

    // 获取自身信息
    Dl_info self_info;
    if (dladdr((const void *)yyds_init, &self_info)) {
        g_self_path = self_info.dli_fname ? strdup(self_info.dli_fname) : NULL;
        g_self_base = self_info.dli_fbase;
        // 提取文件名
        if (g_self_path) {
            const char *slash = strrchr(g_self_path, '/');
            g_self_name = strdup(slash ? slash + 1 : g_self_path);
        }
    }

    // 找到自身在 dyld 中的索引
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && g_self_name && strstr(name, g_self_name)) {
            g_self_index = i;
            break;
        }
    }

    LOGI("INIT", "===========================================");
    LOGI("INIT", "yyds.dylib v1.0 - TSS检测屏蔽器已加载");
    LOGI("INIT", "自身路径: %s", g_self_path ? g_self_path : "(unknown)");
    LOGI("INIT", "自身基址: %p", g_self_base);
    LOGI("INIT", "自身索引: %u", g_self_index);
    LOGI("INIT", "===========================================");

    // 读取初始配置
    yyds_read_config();

    // 注册配置变更通知
    notify_register_dispatch(NOTIFY_NAME, &g_notify_token,
        dispatch_get_main_queue(), ^(int token) {
        yyds_config_changed(NULL);
    });

    // 写入默认配置
    yyds_write_config("shield=1\nmonitor=1\nexit=0\n");
}

// ============================================================
//  ██╗  ██╗ ██████╗  ██████╗ ██╗  ██╗███████╗
//  ██║  ██║██╔═══██╗██╔═══██╗██║ ██╔╝██╔════╝
//  ███████║██║   ██║██║   ██║█████╔╝ ███████╗
//  ██╔══██║██║   ██║██║   ██║██╔═██╗ ╚════██║
//  ██║  ██║╚██████╔╝╚██████╔╝██║  ██╗███████║
//  ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝
// ============================================================

// --------------------------------------------------
// Hook 1: sysctl — 核心!!! 屏蔽 P_TRACED 调试检测
// 分析来源: sub_3F0A8 @ 0x3F0A8
// TSS 通过 sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid())
// 检查 p_flag & P_TRACED (0x800)
// --------------------------------------------------
static int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                      void *newp, size_t newlen) {
    if (!g_shield_enabled) return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    // 记录调用
    if (namelen >= 2) {
        LOGH("sysctl", "mib[0]=%d mib[1]=%d namelen=%u", name[0], name[1], namelen);
    }

    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    if (ret != 0) return ret;

    // --- 屏蔽 P_TRACED (0x800) ---
    // TSS 的 sub_3F0A8 使用 mib = {1, 14, 1, getpid()}
    if (namelen >= 4 && name[0] == CTL_KERN && name[1] == KERN_PROC
        && name[2] == KERN_PROC_PID && oldp && oldlenp) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        if (kp->kp_proc.p_flag & P_TRACED) {
            LOGW("sysctl", "!!! 拦截P_TRACED检测: p_flag=0x%x → 清除0x800",
                 kp->kp_proc.p_flag);
            kp->kp_proc.p_flag &= ~P_TRACED;
        }
    }

    // --- 过滤进程列表 (KERN_PROC_ALL) ---
    // TSS 的 sub_A5854 遍历所有进程找可疑进程
    if (namelen >= 3 && name[0] == CTL_KERN && name[1] == KERN_PROC
        && name[2] == KERN_PROC_ALL && oldp && oldlenp) {
        LOGH("sysctl", "拦截进程列表查询 KERN_PROC_ALL, size=%zu", *oldlenp);
        // 此处可以过滤特定进程名, 但通常只需确保 P_TRACED 被清除即可
    }

    return ret;
}

// --------------------------------------------------
// Hook 2: sysctlbyname — 设备型号查询
// 分析来源: sub_3ABF0 @ 0x3ABF0, sub_125A28 @ 0x125A28
// --------------------------------------------------
static int my_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                            void *newp, size_t newlen) {
    if (!g_shield_enabled)
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);

    LOGH("sysctlbyname", "查询: %s", name ? name : "(null)");
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);

    // 可以在这里修改设备型号返回值, 一般不需要
    return ret;
}

// --------------------------------------------------
// Hook 3: mach_vm_region_recurse — 内存区域枚举
// 分析来源: sub_20167C @ 0x20167C, sub_21196C @ 0x21196C
// TSS 通过此函数遍历进程所有内存区域来检测注入的 dylib
// --------------------------------------------------
static kern_return_t my_mach_vm_region_recurse(
    vm_map_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt) {

    if (!g_shield_enabled || !g_self_base)
        return orig_mach_vm_region(target_task, address, size,
                                   nesting_depth, info, infoCnt);

    kern_return_t kr = orig_mach_vm_region(target_task, address, size,
                                           nesting_depth, info, infoCnt);
    if (kr != KERN_SUCCESS) return kr;

    // 检查当前区域是否属于我们注入的模块
    // 如果地址在我们的模块范围内，跳过该区域
    uintptr_t end = *address + *size;
    uintptr_t self_start = (uintptr_t)g_self_base;
    uintptr_t self_end   = self_start + 0x200000; // 估计最大2MB

    if (*address >= self_start && *address < self_end) {
        LOGH("mach_vm_region", "过滤自身区域: addr=0x%llx size=0x%llx → 跳过",
             (uint64_t)*address, (uint64_t)*size);
        // 跳到该区域之后
        *address = self_end;
        *size = 0;
        // 递归继续查询
        kr = orig_mach_vm_region(target_task, address, size,
                                 nesting_depth, info, infoCnt);
    }

    return kr;
}

// --------------------------------------------------
// Hook 4: vm_region_64 — 内存区域遍历 (旧API)
// 分析来源: sub_17C28C @ 0x17C28C
// --------------------------------------------------
static kern_return_t my_vm_region_64(
    vm_map_t target_task,
    vm_address_t *address,
    vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name) {

    if (!g_shield_enabled || !g_self_base)
        return orig_vm_region_64(target_task, address, size, flavor,
                                  info, infoCnt, object_name);

    kern_return_t kr = orig_vm_region_64(target_task, address, size, flavor,
                                          info, infoCnt, object_name);
    if (kr != KERN_SUCCESS) return kr;

    // 过滤自身模块内存区域
    uintptr_t start = (uintptr_t)g_self_base;
    uintptr_t end   = start + 0x200000;

    if (*address >= start && *address < end) {
        LOGH("vm_region_64", "过滤自身区域: addr=0x%llx → 跳过",
             (uint64_t)*address);
        *address = end;
        *size = 0;
        kr = orig_vm_region_64(target_task, address, size, flavor,
                                info, infoCnt, object_name);
    }

    return kr;
}

// --------------------------------------------------
// Hook 5: proc_regionfilename — 内存区域路径名
// 分析来源: sub_20167C @ 0x20167C, sub_21196C @ 0x21196C
// TSS 通过此函数获取内存区域对应的文件路径来检测注入
// --------------------------------------------------
static int my_proc_regionfilename(int pid, uint64_t address,
                                   void *buffer, uint32_t bufsize) {
    if (!g_shield_enabled || !g_self_base)
        return orig_proc_regionfilename(pid, address, buffer, bufsize);

    // 如果地址在我们的模块范围内, 返回空/伪装值
    uintptr_t start = (uintptr_t)g_self_base;
    uintptr_t end   = start + 0x200000;

    if (address >= start && address < end) {
        LOGH("proc_regionfilename",
             "拦截: pid=%d addr=0x%llx (自身模块) → 返回空", pid, address);
        if (buffer && bufsize > 0) {
            ((char *)buffer)[0] = '\0';
        }
        errno = 0;
        return 0; // 表示成功但返回空
    }

    int ret = orig_proc_regionfilename(pid, address, buffer, bufsize);
    return ret;
}

// --------------------------------------------------
// Hook 6: __dyld_image_count — 动态库计数
// 分析来源: sub_2012CC @ 0x2012CC, sub_153548 @ 0x153548
// --------------------------------------------------
static uint32_t my__dyld_image_count(void) {
    uint32_t real_count = orig__dyld_image_count();

    if (!g_shield_enabled) return real_count;

    // 减少1 (隐藏自身)
    if (real_count > 0) {
        LOGH("dyld", "image_count: %u → %u (隐藏1个)", real_count, real_count - 1);
        return real_count - 1;
    }
    return real_count;
}

// --------------------------------------------------
// Hook 7: __dyld_get_image_name — 动态库名称
// 分析来源: sub_2012CC @ 0x2012CC
// --------------------------------------------------
static const char *my__dyld_get_image_name(uint32_t index) {
    if (!g_shield_enabled || g_self_index == 0xFFFFFFFF)
        return orig__dyld_get_image_name(index);

    // 如果查询我们的索引, 返回 NULL 来隐藏
    if (index == g_self_index) {
        LOGH("dyld", "get_image_name(%u) → 隐藏自身", index);
        return NULL;
    }

    // 对于大于我们索引的, 需要偏移
    if (index >= g_self_index) {
        return orig__dyld_get_image_name(index + 1);
    }

    return orig__dyld_get_image_name(index);
}

// --------------------------------------------------
// Hook 8: __dyld_get_image_header — 动态库头部
// 与 Hook 7 配套, 保持一致性
// --------------------------------------------------
static const struct mach_header *my__dyld_get_image_header(uint32_t index) {
    if (!g_shield_enabled || g_self_index == 0xFFFFFFFF)
        return orig__dyld_get_image_header(index);

    if (index == g_self_index) {
        return NULL;
    }

    if (index >= g_self_index) {
        return orig__dyld_get_image_header(index + 1);
    }

    return orig__dyld_get_image_header(index);
}

// --------------------------------------------------
// Hook 9: dladdr — 地址→模块名解析
// 分析来源: sub_21196C @ 0x21196C, sub_2012CC @ 0x2012CC
// --------------------------------------------------
static int my_dladdr(const void *addr, Dl_info *info) {
    if (!g_shield_enabled || !g_self_base || !info)
        return orig_dladdr(addr, info);

    int ret = orig_dladdr(addr, info);

    if (ret == 0) return ret;

    // 检查是否解析到了我们的模块
    if (g_self_name && info->dli_fname &&
        strstr(info->dli_fname, g_self_name)) {
        LOGH("dladdr", "拦截自身模块解析: addr=%p → 伪装", addr);
        // 伪装成系统库
        static const char *fake_path = "/usr/lib/libSystem.B.dylib";
        info->dli_fname = fake_path;
        info->dli_fbase = NULL;
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
        // 返回 0 表示"解析失败"
        return 0;
    }

    return ret;
}

// --------------------------------------------------
// Hook 10: ptrace — 反反调试
// 阻止 PT_DENY_ATTACH (31)
// --------------------------------------------------
static int my_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (!g_shield_enabled) return orig_ptrace(request, pid, addr, data);

    LOGH("ptrace", "调用: request=%d pid=%d", request, pid);

    // PT_DENY_ATTACH = 31 on iOS/macOS
    if (request == 31) {
        LOGW("ptrace", "!!! 拦截 PT_DENY_ATTACH — 允许调试器附加");
        return 0; // 假装成功, 实际不执行
    }

    // PT_TRACE_ME = 0
    if (request == 0) {
        LOGI("ptrace", "PT_TRACE_ME → 允许放行");
    }

    return orig_ptrace(request, pid, addr, data);
}

// --------------------------------------------------
// Hook 11: task_for_pid — 阻止跨进程访问
// 阻止 TSS 或其他进程通过 task_for_pid 访问游戏进程
// --------------------------------------------------
static kern_return_t my_task_for_pid(mach_port_t target_tport,
                                      pid_t pid, mach_port_t *task) {
    LOGH("task_for_pid", "调用: pid=%d", pid);

    if (!g_shield_enabled)
        return orig_task_for_pid(target_tport, pid, task);

    // 放行自身
    pid_t mypid = getpid();
    if (pid == mypid) {
        return orig_task_for_pid(target_tport, pid, task);
    }

    // 阻止其他跨进程访问
    LOGW("task_for_pid", "拦截跨进程访问: pid=%d (非自身pid=%d)", pid, mypid);
    return KERN_FAILURE;
}

// --------------------------------------------------
// Hook 12: getpid (可选 — 用于调试, 放行)
// --------------------------------------------------
static pid_t my_getpid(void) {
    return orig_getpid();
}

// ============================================================
//  ██╗  ██╗ ██████╗  ██████╗ ██╗  ██╗    ███████╗███████╗████████╗██╗   ██╗██████╗
//  ██║  ██║██╔═══██╗██╔═══██╗██║ ██╔╝    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
//  ███████║██║   ██║██║   ██║█████╔╝     ███████╗█████╗     ██║   ██║   ██║██████╔╝
//  ██╔══██║██║   ██║██║   ██║██╔═██╗     ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝
//  ██║  ██║╚██████╔╝╚██████╔╝██║  ██╗    ███████║███████╗   ██║   ╚██████╔╝██║
//  ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝
// ============================================================

%ctor {
    @autoreleasepool {
        // ---------- MSHookFunction 初始化 ----------
        // sysctl
        MSHookFunction(
            (void *)sysctl,
            (void *)my_sysctl,
            (void **)&orig_sysctl);

        // sysctlbyname
        MSHookFunction(
            (void *)sysctlbyname,
            (void *)my_sysctlbyname,
            (void **)&orig_sysctlbyname);

        // mach_vm_region_recurse (私有API, 动态查找)
        void *mvmr = dlsym(RTLD_DEFAULT, "mach_vm_region_recurse");
        if (mvmr) {
            MSHookFunction(mvmr, (void *)my_mach_vm_region_recurse,
                           (void **)&orig_mach_vm_region);
            LOGI("HOOKSET", "mach_vm_region_recurse ✓");
        } else {
            LOGW("HOOKSET", "mach_vm_region_recurse ✗ (未找到符号)");
        }

        // vm_region_64
        MSHookFunction(
            (void *)vm_region_64,
            (void *)my_vm_region_64,
            (void **)&orig_vm_region_64);

        // proc_regionfilename (私有API)
        void *prf = dlsym(RTLD_DEFAULT, "proc_regionfilename");
        if (prf) {
            MSHookFunction(prf, (void *)my_proc_regionfilename,
                           (void **)&orig_proc_regionfilename);
            LOGI("HOOKSET", "proc_regionfilename ✓");
        } else {
            LOGW("HOOKSET", "proc_regionfilename ✗ (未找到符号)");
        }

        // dyld 函数
        MSHookFunction(
            (void *)_dyld_image_count,
            (void *)my__dyld_image_count,
            (void **)&orig__dyld_image_count);

        MSHookFunction(
            (void *)_dyld_get_image_name,
            (void *)my__dyld_get_image_name,
            (void **)&orig__dyld_get_image_name);

        MSHookFunction(
            (void *)_dyld_get_image_header,
            (void *)my__dyld_get_image_header,
            (void **)&orig__dyld_get_image_header);

        // dladdr
        MSHookFunction(
            (void *)dladdr,
            (void *)my_dladdr,
            (void **)&orig_dladdr);

        // ptrace
        MSHookFunction(
            (void *)ptrace,
            (void *)my_ptrace,
            (void **)&orig_ptrace);

        // task_for_pid
        MSHookFunction(
            (void *)task_for_pid,
            (void *)my_task_for_pid,
            (void **)&orig_task_for_pid);

        // getpid
        MSHookFunction(
            (void *)getpid,
            (void *)my_getpid,
            (void **)&orig_getpid);

        LOGI("HOOKSET", "全部 12 个 Hook 已安装完成");
        LOGI("HOOKSET", "屏蔽状态: %s", g_shield_enabled ? "已启用" : "已停用");
        LOGI("HOOKSET", "监控状态: %s", g_monitor_enabled ? "已启用" : "已停用");
    }
}
