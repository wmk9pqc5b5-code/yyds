/**
 * YYDSRootListController.m
 * yyds 偏好设置控制器 — 滑块1启动屏蔽 / 滑块2退出屏蔽 / 滑块3查看监控 / 滑块4退出
 */
#import "YYDSRootListController.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <unistd.h>
#import <spawn.h>

#define CONFIG_PATH  "/var/mobile/Documents/yyds_config.txt"
#define LOG_PATH     "/var/mobile/Documents/yyds_log.txt"
#define NOTIFY_NAME  "com.yyds.bypass.config_changed"

@implementation YYDSRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// ========== 滑块1: 启动屏蔽 ==========
- (void)slider1_start_shield {
    [self writeConfig:"shield=1\nmonitor=1\nexit=0\n"];
    notify_post(NOTIFY_NAME);

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"yyds 屏蔽系统"
        message:@"✅ 屏蔽已启动!\n\n"
                "• sysctl P_TRACED 检测 → 已屏蔽\n"
                "• 内存区域枚举 → 已屏蔽\n"
                "• dyld 镜像检测 → 已屏蔽\n"
                "• proc_regionfilename → 已屏蔽\n"
                "• dladdr 模块解析 → 已屏蔽\n"
                "• PT_DENY_ATTACH → 已拦截\n"
                "• 监控日志 → 已启用\n\n"
                "现在可以安全注入内存修改工具!"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ========== 滑块2: 退出屏蔽 ==========
- (void)slider2_stop_shield {
    [self writeConfig:"shield=0\nmonitor=1\nexit=0\n"];
    notify_post(NOTIFY_NAME);

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"yyds 屏蔽系统"
        message:@"⚠️ 屏蔽已退出!\n\n"
                "所有检测函数已恢复原始行为。\n"
                "监控日志仍在运行。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ========== 滑块3: 查看监控日志 ==========
- (void)slider3_view_monitor {
    // 强制刷新日志到磁盘
    [self writeConfig:"shield=1\nmonitor=1\nexit=0\n"];
    notify_post(NOTIFY_NAME);

    // 创建一个完整的日志查看界面
    UIViewController *logVC = [[UIViewController alloc] init];
    logVC.title = @"yyds 监控日志";
    logVC.view.backgroundColor = [UIColor blackColor];

    UITextView *textView = [[UITextView alloc] initWithFrame:logVC.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    textView.textColor = [UIColor greenColor];
    textView.font = [UIFont fontWithName:@"Menlo" size:11];
    textView.editable = NO;
    textView.autocorrectionType = UITextAutocorrectionTypeNo;

    // 读取日志
    NSString *logContent = [NSString stringWithContentsOfFile:@(LOG_PATH)
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    if (!logContent || logContent.length == 0) {
        textView.text = @"📭 暂无监控日志\n\n请确保:\n1. yyds.dylib 已正确注入\n2. 游戏正在运行\n3. 屏蔽功能已启动";
        textView.textColor = [UIColor yellowColor];
    } else {
        // 取最后 8000 字符显示
        if (logContent.length > 8000) {
            logContent = [logContent substringFromIndex:logContent.length - 8000];
        }
        textView.text = [NSString stringWithFormat:@"=== yyds 监控日志 (最新) ===\n\n%@", logContent];

        // 高亮关键行
        NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] initWithString:textView.text];
        NSString *text = textView.text;
        NSArray *lines = [text componentsSeparatedByString:@"\n"];
        NSUInteger loc = 0;
        for (NSString *line in lines) {
            NSRange lineRange = NSMakeRange(loc, line.length);
            if ([line containsString:@"!!!"]) {
                [attrStr addAttribute:NSForegroundColorAttributeName
                                value:[UIColor redColor] range:lineRange];
            } else if ([line containsString:@"HOOK"]) {
                [attrStr addAttribute:NSForegroundColorAttributeName
                                value:[UIColor cyanColor] range:lineRange];
            } else if ([line containsString:@"WARN"]) {
                [attrStr addAttribute:NSForegroundColorAttributeName
                                value:[UIColor yellowColor] range:lineRange];
            } else if ([line containsString:@"INIT"] || [line containsString:@"HOOKSET"]) {
                [attrStr addAttribute:NSForegroundColorAttributeName
                                value:[UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0]
                                range:lineRange];
            }
            loc += line.length + 1; // +1 for \n
        }
        textView.attributedText = attrStr;
    }

    // 滑动到末尾
    NSRange endRange = NSMakeRange(textView.text.length - 1, 0);
    [textView scrollRangeToVisible:endRange];

    [logVC.view addSubview:textView];

    // 刷新按钮
    UIButton *refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshBtn.frame = CGRectMake(0, logVC.view.bounds.size.height - 50,
                                   logVC.view.bounds.size.width, 50);
    refreshBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [refreshBtn setTitle:@"🔄 刷新日志" forState:UIControlStateNormal];
    [refreshBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    refreshBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
    refreshBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];

    // 刷新逻辑: 重新打开本页面
    __weak typeof(self) weakSelf = self;
    [refreshBtn addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        [logVC dismissViewControllerAnimated:YES completion:^{
            [weakSelf slider3_view_monitor];
        }];
    }] forControlEvents:UIControlEventTouchUpInside];

    [logVC.view addSubview:refreshBtn];

    // 关闭按钮
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(dismissLogView)];
    logVC.navigationItem.rightBarButtonItem = closeBtn;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dismissLogView {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ========== 滑块4: 退出程序 (Respring) ==========
- (void)slider4_exit_program {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"yyds — 退出程序"
        message:@"确定要退出吗?\n\n"
                "这将重新启动设备桌面 (Respring)，\n"
                "yyds.dylib 将从内存中卸载。\n\n"
                "💡 提示: 如需重新使用, 重新打开游戏即可。"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定退出"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self performExit];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performExit {
    // 写入退出配置
    [self writeConfig:"shield=0\nmonitor=0\nexit=1\n"];
    notify_post(NOTIFY_NAME);

    // Respring (重启 SpringBoard)
    pid_t pid;
    extern char **environ;
    const char *args[] = {
        "killall",
        "-9",
        "SpringBoard",
        NULL
    };
    int status;
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, environ);
    waitpid(pid, &status, 0);
}

// ========== 辅助方法 ==========

- (void)writeConfig:(const char *)cfg {
    int fd = open(CONFIG_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, cfg, strlen(cfg));
        close(fd);
    }
}

@end
