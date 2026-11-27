// Islet Now Playing helper.
//
// Since macOS 15.4, mediaremoted only answers Apple-signed processes, so this small library is
// loaded into Apple's /usr/bin/perl (see lwmr.pl), which may read system-wide Now Playing for any
// app (Spotify, YouTube Music in a browser, Music, Podcasts, VLC…).
//
// Output: one JSON object per line on stdout whenever Now Playing changes.
// Input (stdin, one per line): toggle | play | pause | next | previous | seek <seconds>
//
// Build: clang -dynamiclib -fobjc-arc -framework Foundation -framework AppKit -o LWMediaRemote.dylib lwmr.m

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetPID getPID;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;
static NSUInteger lastArtworkHash;
static BOOL pending;

static NSString *str(id value) { return [value isKindOfClass:[NSString class]] ? value : nil; }
static NSNumber *num(id value) { return [value isKindOfClass:[NSNumber class]] ? value : nil; }

static void write_line(NSDictionary *object) {
    // dataWithJSONObject throws (it doesn't return nil) on NaN/Inf, which killed the helper.
    if (![NSJSONSerialization isValidJSONObject:object]) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emit(void) {
    pending = NO;
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getPID(dispatch_get_main_queue(), ^(int pid) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"type"] = @"nowPlaying";
                out[@"playing"] = @(playing);
                NSString *title = str(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                if (title.length == 0) {
                    // The app drops its artwork on "empty"; forget ours too so the same song coming
                    // back sends its art again instead of showing a blank square.
                    lastArtworkHash = 0;
                    write_line(@{@"type": @"nowPlaying", @"empty": @YES});
                    return;
                }
                out[@"title"] = title;
                out[@"artist"] = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]) ?: @"";
                out[@"album"] = str(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: @"";
                NSNumber *duration = num(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                if (duration && isfinite(duration.doubleValue)) out[@"duration"] = duration;
                NSNumber *elapsed = num(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                if (elapsed && isfinite(elapsed.doubleValue)) out[@"elapsed"] = elapsed;
                NSNumber *rate = num(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                if (rate && isfinite(rate.doubleValue)) out[@"rate"] = rate;
                id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([timestamp isKindOfClass:[NSDate class]] && isfinite([(NSDate *)timestamp timeIntervalSince1970])) out[@"timestamp"] = @([(NSDate *)timestamp timeIntervalSince1970]);
                NSNumber *shuffle = num(info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"]);
                if (shuffle) out[@"shuffle"] = shuffle;
                NSNumber *repeat = num(info[@"kMRMediaRemoteNowPlayingInfoRepeatMode"]);
                if (repeat) out[@"repeat"] = repeat;
                NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                if (app.bundleIdentifier) out[@"bundleIdentifier"] = app.bundleIdentifier;
                if (app.localizedName) out[@"appName"] = app.localizedName;
                id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([artwork isKindOfClass:[NSData class]]) {
                    NSUInteger hash = [(NSData *)artwork hash] ^ [(NSData *)artwork length];
                    if (hash != lastArtworkHash) {
                        lastArtworkHash = hash;
                        out[@"artwork"] = [(NSData *)artwork base64EncodedStringWithOptions:0];
                    }
                } else {
                    lastArtworkHash = 0;
                    out[@"artworkCleared"] = @YES;
                }
                write_line(out);
            });
        });
    });
}

static void schedule_emit(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ emit(); });
}

static MRRegister registerFn;

static void handle_command(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    // MRMediaRemoteCommand: 0 play, 1 pause, 2 toggle, 4 next track, 5 previous track
    if ([cmd isEqualToString:@"toggle"]) sendCommand(2, nil);
    else if ([cmd isEqualToString:@"play"]) sendCommand(0, nil);
    else if ([cmd isEqualToString:@"pause"]) sendCommand(1, nil);
    else if ([cmd isEqualToString:@"next"]) sendCommand(4, nil);
    else if ([cmd isEqualToString:@"previous"]) sendCommand(5, nil);
    else if ([cmd isEqualToString:@"like"]) sendCommand(106, nil); // MRMediaRemoteCommandLikeTrack
    else if ([cmd isEqualToString:@"shuffle"]) sendCommand(6, nil); // toggle shuffle
    else if ([cmd isEqualToString:@"repeat"]) sendCommand(7, nil);  // toggle repeat
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) {
        // Sent by the app after wake/unlock: mediaremoted may have restarted and forgotten our
        // registration, so register again (harmless if it didn't) and re-read the current state.
        if (registerFn) registerFn(dispatch_get_main_queue());
        schedule_emit();
    }
}

// Called from perl via DynaLoader::dl_install_xsub; perl passes (interpreter, cv), which we ignore.
void lw_stream(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { write_line(@{@"type": @"error", @"message": @"MediaRemote not found"}); exit(2); }
    getInfo = (MRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetIsPlaying)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (MRGetPID)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (MRSendCommand)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegister reg = (MRRegister)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getPID || !sendCommand || !reg) {
        write_line(@{@"type": @"error", @"message": @"MediaRemote symbols missing"});
        exit(3);
    }

    registerFn = reg;
    reg(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { schedule_emit(); }];
    }

    // Commands from the app on stdin; exit when the app goes away (stdin closes).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            dispatch_async(dispatch_get_main_queue(), ^{ handle_command(line); });
        }
        exit(0);
    });

    write_line(@{@"type": @"ready"});
    emit();
    CFRunLoopRun();
}
