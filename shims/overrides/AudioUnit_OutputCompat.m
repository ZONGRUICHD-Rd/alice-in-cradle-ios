// AudioUnit macOS -> iOS RemoteIO output adapter.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>

#define EXPORT __attribute__((visibility("default")))

static void *AudioToolboxHandle(void) {
    static void *h = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
    });
    return h;
}

static void EnsureAudioSessionActive(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AVAudioSession *session = AVAudioSession.sharedInstance;
        NSError *err = nil;
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err];
        [session setPreferredIOBufferDuration:0.005 error:nil];
        [session setActive:YES error:&err];
        if (err) {
            NSLog(@"AIC-SHIM AVAudioSession init note: %@", err.localizedDescription);
        }
    });
}

EXPORT AudioComponent AudioComponentFindNext(AudioComponent previous, const AudioComponentDescription *desc) {
    EnsureAudioSessionActive();
    typedef AudioComponent (*Fn)(AudioComponent, const AudioComponentDescription *);
    static Fn orig = NULL;
    if (!orig) orig = (Fn)dlsym(AudioToolboxHandle(), "AudioComponentFindNext");
    if (!orig || !desc) return NULL;

    AudioComponentDescription mapped = *desc;
    // Map macOS HALOutput ('ahal'), DefaultOutput ('def '), SystemOutput ('sys ') to iOS RemoteIO
    if (mapped.componentType == kAudioUnitType_Output &&
        (mapped.componentSubType == 'ahal' || mapped.componentSubType == 'def ' || mapped.componentSubType == 'sys ')) {
        mapped.componentSubType = kAudioUnitSubType_RemoteIO;
    }
    return orig(previous, &mapped);
}

EXPORT OSStatus AudioUnitSetProperty(
    AudioUnit unit,
    AudioUnitPropertyID prop,
    AudioUnitScope scope,
    AudioUnitElement element,
    const void *data,
    UInt32 size
) {
    EnsureAudioSessionActive();
    // macOS kAudioOutputUnitProperty_CurrentDevice (2000) is not used on iOS RemoteIO
    if (prop == 2000) return noErr;

    typedef OSStatus (*Fn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
    static Fn orig = NULL;
    if (!orig) orig = (Fn)dlsym(AudioToolboxHandle(), "AudioUnitSetProperty");
    if (!orig) return -1;

    AudioStreamBasicDescription patchedFmt;
    if (prop == kAudioUnitProperty_StreamFormat && data && size >= sizeof(AudioStreamBasicDescription)) {
        patchedFmt = *(const AudioStreamBasicDescription *)data;
        if (!(patchedFmt.mSampleRate > 0)) {
            patchedFmt.mSampleRate = AVAudioSession.sharedInstance.sampleRate ?: 48000.0;
        }
        data = &patchedFmt;
    }
    return orig(unit, prop, scope, element, data, size);
}

EXPORT OSStatus AudioUnitGetProperty(
    AudioUnit unit,
    AudioUnitPropertyID prop,
    AudioUnitScope scope,
    AudioUnitElement element,
    void *data,
    UInt32 *size
) {
    typedef OSStatus (*Fn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);
    static Fn orig = NULL;
    if (!orig) orig = (Fn)dlsym(AudioToolboxHandle(), "AudioUnitGetProperty");
    if (!orig) return -1;

    OSStatus r = orig(unit, prop, scope, element, data, size);
    if (r == noErr && prop == kAudioUnitProperty_StreamFormat && data && size && *size >= sizeof(AudioStreamBasicDescription)) {
        AudioStreamBasicDescription *fmt = (AudioStreamBasicDescription *)data;
        if (!(fmt->mSampleRate > 0)) {
            fmt->mSampleRate = AVAudioSession.sharedInstance.sampleRate ?: 48000.0;
        }
    }
    return r;
}
