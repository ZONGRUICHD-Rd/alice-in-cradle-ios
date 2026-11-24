// CoreAudio HAL compatibility shim for Unity FMOD/CoreAudio on iOS 27.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct {
    UInt32 mSelector;
    UInt32 mScope;
    UInt32 mElement;
} AICAudioObjectPropertyAddress;

static const OSStatus kAICUnknownProp = 2003332927; // 'who?'
static const UInt32 kAICOutputDeviceID = 2;

static UInt32 AICAudioPropSize(UInt32 selector, BOOL isInput) {
    switch (selector) {
        case 'dev#': case 'dOut': case 'dSys': case 'dIn ': case 'livn':
        case 'dflt': case 'fsiz': case 'ltnc': case 'saft': case 'stm#':
        case 'goin': case 'hogm': case 'jack': case 'mute':
            return sizeof(UInt32);
        case 'name': return (UInt32)sizeof("iPhone 18 Pro Audio");
        case 'manu': return (UInt32)sizeof("Apple");
        case 'lnam': case 'uid ': case 'lmak': return (UInt32)sizeof(CFStringRef);
        case 'nsrt': return (UInt32)sizeof(Float64);
        case 'nsr#': case 'fsz#': return (UInt32)sizeof(AudioValueRange);
        case 'sfmt': return (UInt32)sizeof(AudioStreamBasicDescription);
        case 'srnd': return (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions);
        case 'slay': return isInput ? (UInt32)offsetof(AudioBufferList, mBuffers) : (UInt32)sizeof(AudioBufferList);
        default: return 0;
    }
}

static OSStatus AICAudioReadProp(UInt32 selector, BOOL isInput, UInt32 *ioSize, void *outData) {
    UInt32 need = AICAudioPropSize(selector, isInput);
    if (!need) return kAICUnknownProp;
    if (!ioSize || !outData || *ioSize < need) return 'psiz';
    memset(outData, 0, need);

    Float64 rate = AVAudioSession.sharedInstance.sampleRate;
    if (rate <= 0) rate = 48000.0;

    switch (selector) {
        case 'dev#': case 'dOut': case 'dSys': *(UInt32 *)outData = kAICOutputDeviceID; break;
        case 'dIn ': *(UInt32 *)outData = 0; break;
        case 'livn': case 'dflt': case 'goin': case 'jack': *(UInt32 *)outData = 1; break;
        case 'hogm': *(int32_t *)outData = -1; break;
        case 'stm#': *(UInt32 *)outData = isInput ? 0 : 3; break;
        case 'fsiz': *(UInt32 *)outData = 512; break;
        case 'ltnc': case 'saft': case 'mute': *(UInt32 *)outData = 0; break;
        case 'name': memcpy(outData, "iPhone 18 Pro Audio", need); break;
        case 'manu': memcpy(outData, "Apple", need); break;
        case 'lnam': case 'uid ': case 'lmak': {
            CFStringRef val = (selector == 'uid ') ? CFSTR("com.alicecradle.ios.audio.out")
                            : (selector == 'lmak') ? CFSTR("Apple")
                            : CFSTR("iPhone 18 Pro Audio");
            *(CFStringRef *)outData = CFRetain(val);
            break;
        }
        case 'nsrt': *(Float64 *)outData = rate; break;
        case 'nsr#': *(AudioValueRange *)outData = (AudioValueRange){rate, rate}; break;
        case 'fsz#': *(AudioValueRange *)outData = (AudioValueRange){128, 4096}; break;
        case 'slay': {
            AudioBufferList *list = (AudioBufferList *)outData;
            list->mNumberBuffers = isInput ? 0 : 1;
            if (!isInput) {
                list->mBuffers[0].mNumberChannels = 2;
                list->mBuffers[0].mDataByteSize = 0;
                list->mBuffers[0].mData = NULL;
            }
            break;
        }
        case 'srnd':
            ((AudioChannelLayout *)outData)->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            break;
        case 'sfmt': {
            AudioStreamBasicDescription *fmt = (AudioStreamBasicDescription *)outData;
            *fmt = (AudioStreamBasicDescription){
                .mSampleRate = rate,
                .mFormatID = kAudioFormatLinearPCM,
                .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                .mBytesPerPacket = 8,
                .mFramesPerPacket = 1,
                .mBytesPerFrame = 8,
                .mChannelsPerFrame = 2,
                .mBitsPerChannel = 32,
                .mReserved = 0
            };
            break;
        }
    }
    *ioSize = need;
    return noErr;
}

EXPORT OSStatus AudioHardwareGetPropertyInfo(UInt32 selector, UInt32 *size, Boolean *writable) {
    UInt32 need = AICAudioPropSize(selector, NO);
    if (!need) return kAICUnknownProp;
    if (size) *size = need;
    if (writable) *writable = false;
    return noErr;
}

EXPORT OSStatus AudioHardwareGetProperty(UInt32 selector, UInt32 *size, void *out) {
    return AICAudioReadProp(selector, NO, size, out);
}

EXPORT OSStatus AudioHardwareAddPropertyListener(UInt32 selector, void *listener, void *ctx) {
    (void)selector; (void)listener; (void)ctx;
    return noErr;
}

EXPORT OSStatus AudioHardwareRemovePropertyListener(UInt32 selector, void *listener) {
    (void)selector; (void)listener;
    return noErr;
}

EXPORT OSStatus AudioDeviceGetPropertyInfo(UInt32 dev, UInt32 chan, Boolean isInput, UInt32 selector, UInt32 *size, Boolean *writable) {
    (void)dev; (void)chan;
    UInt32 need = AICAudioPropSize(selector, isInput);
    if (!need) return kAICUnknownProp;
    if (size) *size = need;
    if (writable) *writable = false;
    return noErr;
}

EXPORT OSStatus AudioDeviceGetProperty(UInt32 dev, UInt32 chan, Boolean isInput, UInt32 selector, UInt32 *size, void *out) {
    (void)dev; (void)chan;
    return AICAudioReadProp(selector, isInput, size, out);
}

EXPORT OSStatus AudioDeviceSetProperty(UInt32 dev, const void *when, UInt32 chan, Boolean isInput, UInt32 selector, UInt32 size, const void *data) {
    (void)dev; (void)when; (void)chan; (void)isInput; (void)selector; (void)size; (void)data;
    return noErr;
}

EXPORT Boolean AudioObjectHasProperty(UInt32 objectID, const AICAudioObjectPropertyAddress *addr) {
    (void)objectID;
    if (!addr) return false;
    BOOL isInput = (addr->mScope == 'inpt');
    return AICAudioPropSize(addr->mSelector, isInput) > 0;
}

EXPORT OSStatus AudioObjectIsPropertySettable(UInt32 objectID, const AICAudioObjectPropertyAddress *addr, Boolean *outSettable) {
    (void)objectID; (void)addr;
    if (outSettable) *outSettable = false;
    return noErr;
}

EXPORT OSStatus AudioObjectGetPropertyDataSize(UInt32 objectID, const AICAudioObjectPropertyAddress *addr, UInt32 qualSize, const void *qualData, UInt32 *outSize) {
    (void)objectID; (void)qualSize; (void)qualData;
    if (!addr || !outSize) return kAICUnknownProp;
    BOOL isInput = (addr->mScope == 'inpt');
    UInt32 need = AICAudioPropSize(addr->mSelector, isInput);
    if (!need) return kAICUnknownProp;
    *outSize = need;
    return noErr;
}

EXPORT OSStatus AudioObjectGetPropertyData(UInt32 objectID, const AICAudioObjectPropertyAddress *addr, UInt32 qualSize, const void *qualData, UInt32 *ioSize, void *outData) {
    (void)objectID; (void)qualSize; (void)qualData;
    if (!addr) return kAICUnknownProp;
    BOOL isInput = (addr->mScope == 'inpt');
    return AICAudioReadProp(addr->mSelector, isInput, ioSize, outData);
}

EXPORT OSStatus AudioObjectSetPropertyData(UInt32 objectID, const AICAudioObjectPropertyAddress *addr, UInt32 qualSize, const void *qualData, UInt32 dataSize, const void *inData) {
    (void)objectID; (void)addr; (void)qualSize; (void)qualData; (void)dataSize; (void)inData;
    return noErr;
}

EXPORT OSStatus AudioObjectAddPropertyListener(UInt32 objectID, const AICAudioObjectPropertyAddress *addr, void *listener, void *clientData) {
    (void)objectID; (void)addr; (void)listener; (void)clientData;
    return noErr;
}

EXPORT OSStatus AudioObjectRemovePropertyListener(UInt32 objectID, const AICAudioObjectPropertyAddress *addr, void *listener, void *clientData) {
    (void)objectID; (void)addr; (void)listener; (void)clientData;
    return noErr;
}
