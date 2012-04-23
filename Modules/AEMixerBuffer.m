//
//  AEMixerBuffer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 12/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEMixerBuffer.h"
#import "TPCircularBuffer.h"
#import "TPCircularBuffer+AudioBufferList.h"
#import <libkern/OSAtomic.h>
#import <mach/mach_time.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/'),__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

static const int               kMaxSources                             = 10;
static const NSTimeInterval    kSourceTimestampThreshold               = 0.0025;
static const NSTimeInterval    kSourceTimestampIdleThreshold           = 0.1;
static const int               kConversionBufferLength                 = 16384;
static const int               kScratchBufferLength                    = 16384;
static const int               kSourceBufferLength                     = 16384;

typedef struct {
    AEMixerBufferSource                source;
    AEMixerBufferSourcePeekCallback    peekCallback;
    AEMixerBufferSourceRenderCallback  renderCallback;
    void                                   *callbackUserinfo;
    TPCircularBuffer                        buffer;
    uint64_t                                lastAudioTimestamp;
    BOOL                                    processedForCurrentTimeSlice;
    AudioStreamBasicDescription             audioDescription;
    float                                   volume;
    float                                   pan;
} source_t;

typedef void(*AEMixerBufferAction)(AEMixerBuffer *buffer, void *userInfo);

typedef struct {
    AEMixerBufferAction action;
    void *userInfo;
} action_t;

const int               kActionBufferSize                       = sizeof(action_t) * 10;
const NSTimeInterval    kActionMainThreadPollDuration           = 0.2;

@interface AEMixerBuffer () {
    AudioStreamBasicDescription _clientFormat;
    AudioStreamBasicDescription _mixerOutputFormat;
    source_t                    _table[kMaxSources];
    uint64_t                    _currentSliceSampleTime;
    uint64_t                    _currentSliceTimestamp;
    UInt32                      _currentSliceFrameCount;
    AUGraph                     _graph;
    AUNode                      _mixerNode;
    AudioUnit                   _mixerUnit;
    AudioConverterRef           _audioConverter;
    TPCircularBuffer            _audioConverterBuffer;
    BOOL                        _audioConverterHasBuffer;
    uint8_t                    *_scratchBuffer;
    BOOL                        _graphReady;
    TPCircularBuffer            _mainThreadActionBuffer;
    NSTimer                    *_mainThreadActionPollTimer;
}

static inline source_t *sourceWithID(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, int* index);
static void prepareNewSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID);
- (void)refreshMixingGraph;
@end

@interface AEMixerBufferProxy : NSProxy {
    AEMixerBuffer *_mixerBuffer;
}
- (id)initWithMixerBuffer:(AEMixerBuffer*)mixerBuffer;
@end

@implementation AEMixerBuffer

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

- (id)initWithAudioDescription:(AudioStreamBasicDescription)audioDescription {
    if ( !(self = [super init]) ) return nil;
    
    _clientFormat = audioDescription;
    _scratchBuffer = (uint8_t*)malloc(kScratchBufferLength);

    TPCircularBufferInit(&_mainThreadActionBuffer, kActionBufferSize);
    _mainThreadActionPollTimer = [NSTimer scheduledTimerWithTimeInterval:kActionMainThreadPollDuration
                                                                  target:[[[AEMixerBufferProxy alloc] initWithMixerBuffer:self] autorelease]
                                                                selector:@selector(pollActionBuffer) 
                                                                userInfo:nil
                                                                 repeats:YES];
    return self;
}

- (void)dealloc {
    [_mainThreadActionPollTimer invalidate];
    TPCircularBufferCleanup(&_mainThreadActionBuffer);
    
    if ( _graph ) {
        checkResult(AUGraphClose(_graph), "AUGraphClose");
        checkResult(DisposeAUGraph(_graph), "AUGraphClose");
    }
    
    if ( _audioConverter ) {
        checkResult(AudioConverterDispose(_audioConverter), "AudioConverterDispose");
        _audioConverter = NULL;
        TPCircularBufferCleanup(&_audioConverterBuffer);
    }
    
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source ) {
            if ( !_table[i].renderCallback ) {
                TPCircularBufferCleanup(&_table[i].buffer);
            }
        }
    }
    
    [super dealloc];
}

void AEMixerBufferEnqueue(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, AudioBufferList *audio, UInt32 lengthInFrames, UInt64 hostTime) {
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    if ( !source ) {
        if ( pthread_main_np() != 0 ) {
            prepareNewSource(THIS, sourceID);
            source = sourceWithID(THIS, sourceID, NULL);
        } else {
            action_t action = {.action = prepareNewSource, .userInfo = sourceID};
            TPCircularBufferProduceBytes(&THIS->_mainThreadActionBuffer, &action, sizeof(action));
            return;
        }
    }
    
    if ( !audio ) return;
    
    assert(!source->renderCallback);

    AudioTimeStamp audioTimestamp;
    memset(&audioTimestamp, 0, sizeof(audioTimestamp));
    audioTimestamp.mFlags = kAudioTimeStampHostTimeValid;
    audioTimestamp.mHostTime = hostTime;
    if ( !TPCircularBufferCopyAudioBufferList(&source->buffer, audio, &audioTimestamp) ) {
#ifdef DEBUG
        printf("Out of buffer space in AEMixerBuffer\n");  
#endif
    }
}

- (void)setRenderCallback:(AEMixerBufferSourceRenderCallback)renderCallback peekCallback:(AEMixerBufferSourcePeekCallback)peekCallback userInfo:(void *)userInfo forSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    
    if ( !source ) {
        source = sourceWithID(self, NULL, NULL);
        if ( !source ) return;
        memset(source, 0, sizeof(source_t));
        source->source = sourceID;
        source->volume = 1.0;
        source->pan = 0.0;
        source->audioDescription = _clientFormat;
        [self refreshMixingGraph];
    } else {
        TPCircularBufferCleanup(&source->buffer);
    }
    
    source->renderCallback = renderCallback;
    source->peekCallback = peekCallback;
    source->callbackUserinfo = userInfo;
}

void AEMixerBufferDequeue(AEMixerBuffer *THIS, AudioBufferList *bufferList, UInt32 *ioLengthInFrames) {
    if ( !THIS->_graphReady ) {
        *ioLengthInFrames = 0;
        return;
    }
    
    // If buffer list is provided with NULL mData pointers, use our own scratch buffer
    if ( bufferList && !bufferList->mBuffers[0].mData ) {
        assert(*ioLengthInFrames * THIS->_clientFormat.mBytesPerFrame * bufferList->mNumberBuffers <= kScratchBufferLength);
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = THIS->_scratchBuffer + i*(kScratchBufferLength/bufferList->mNumberBuffers);
            bufferList->mBuffers[i].mDataByteSize = kScratchBufferLength/bufferList->mNumberBuffers;
        }
    }
    
    // Determine how many frames are available globally
    uint64_t sliceTimestamp = sliceTimestamp;
    UInt32 sliceFrameCount = AEMixerBufferPeek(THIS, &sliceTimestamp);
    THIS->_currentSliceTimestamp = sliceTimestamp;
    THIS->_currentSliceFrameCount = sliceFrameCount;
    
    if ( bufferList ) {
        *ioLengthInFrames = MIN(*ioLengthInFrames, bufferList->mBuffers[0].mDataByteSize / THIS->_clientFormat.mBytesPerFrame);
    }
    
    *ioLengthInFrames = MIN(*ioLengthInFrames, sliceFrameCount);
    
    if ( !bufferList ) {
        // Just consume frames
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) {
                AEMixerBufferDequeueSingleSource(THIS, THIS->_table[i].source, NULL, ioLengthInFrames);
            }
        }
        return;
    }
    
    int numberOfSources = 0;
    AEMixerBufferSource firstSource = NULL;
    source_t *firstSourceEntry = NULL;
    for ( int i=0; i<kMaxSources && numberOfSources < 2; i++ ) {
        if ( THIS->_table[i].source ) {
            if ( !firstSource ) {
                firstSource = THIS->_table[i].source;
                firstSourceEntry = &THIS->_table[i];
            }
            numberOfSources++;
        }
    }
    
    if ( numberOfSources == 1 && memcmp(&firstSourceEntry->audioDescription, &THIS->_clientFormat, sizeof(AudioStreamBasicDescription)) == 0 ) {
        // Just one source, with the same audio format - pull straight from it
        AEMixerBufferDequeueSingleSource(THIS, firstSource, bufferList, ioLengthInFrames);
        return;
    }
    
    // We'll advance the buffer list pointers as we add audio - save the originals to restore later
    void *savedmData[2] = { bufferList ? bufferList->mBuffers[0].mData : NULL, bufferList && bufferList->mNumberBuffers == 2 ? bufferList->mBuffers[1].mData : NULL };
    
    int framesToGo = *ioLengthInFrames;
    while ( framesToGo > 0 ) {
        // Process in small blocks so we don't overwhelm the mixer/converter buffers
        UInt32 frames = MIN(framesToGo, 512);
        
        AudioBufferList *intermediateBufferList = bufferList;
    
        if ( THIS->_audioConverter ) {
            // Initialise output buffer (to receive audio in mixer format)
            intermediateBufferList = TPCircularBufferPrepareEmptyAudioBufferList(&THIS->_audioConverterBuffer, 
                                                                                 THIS->_mixerOutputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? THIS->_mixerOutputFormat.mChannelsPerFrame : 1, 
                                                                                 frames * THIS->_mixerOutputFormat.mBytesPerFrame,
                                                                                 NULL);
            assert(intermediateBufferList != NULL);
            
            for ( int i=0; i<intermediateBufferList->mNumberBuffers; i++ ) {
                intermediateBufferList->mBuffers[i].mNumberChannels = THIS->_mixerOutputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : THIS->_mixerOutputFormat.mChannelsPerFrame;
            }
        }
        
        // Perform render
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp audioTimestamp;
        memset(&audioTimestamp, 0, sizeof(audioTimestamp));
        audioTimestamp.mFlags = (sliceTimestamp ? kAudioTimeStampHostTimeValid : 0) | kAudioTimeStampSampleTimeValid;
        audioTimestamp.mHostTime = sliceTimestamp;
        audioTimestamp.mSampleTime = THIS->_currentSliceSampleTime;
        OSStatus result = AudioUnitRender(THIS->_mixerUnit, &flags, &audioTimestamp, 0, frames, intermediateBufferList);
        if ( !checkResult(result, "AudioUnitRender") ) break;
    
        THIS->_currentSliceSampleTime += frames;
        
        if ( THIS->_audioConverter ) {
            // Convert output into client format
            OSStatus result = AudioConverterConvertComplexBuffer(THIS->_audioConverter, frames, intermediateBufferList, bufferList);
            if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) break;
        }
        
        // Advance buffers
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = (uint8_t*)bufferList->mBuffers[i].mData + (frames * THIS->_clientFormat.mBytesPerFrame);
            bufferList->mBuffers[i].mDataByteSize -= frames * THIS->_clientFormat.mBytesPerFrame;
        }
        
        if ( frames == 0 ) break;
        
        framesToGo -= frames;
    }
    
    *ioLengthInFrames -= framesToGo;
    
    // Restore buffers
    if ( bufferList ) {
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = savedmData[i];
            bufferList->mBuffers[i].mDataByteSize = *ioLengthInFrames * THIS->_clientFormat.mBytesPerFrame;
        }
    }
}


void AEMixerBufferDequeueSingleSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, AudioBufferList *bufferList, UInt32 *ioLengthInFrames) {
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    
    uint64_t sliceTimestamp = THIS->_currentSliceTimestamp;
    UInt32 sliceFrameCount = THIS->_currentSliceFrameCount;
    
    if ( sliceTimestamp == 0 ) {
        // Determine how many frames are available globally
        sliceFrameCount = AEMixerBufferPeek(THIS, &sliceTimestamp);
        THIS->_currentSliceTimestamp = sliceTimestamp;
        THIS->_currentSliceFrameCount = sliceFrameCount;
    }
    
    uint64_t sourceTimestamp = 0;
    UInt32 sourceFrameCount = 0;
    
    if ( sliceFrameCount > 0 ) {
        // Now determine the frame count and timestamp on the current source
        if ( source->peekCallback ) {
            sourceFrameCount = source->peekCallback(source->source, &sourceTimestamp, source->callbackUserinfo);
        } else {
            AudioTimeStamp audioTimestamp;
            sourceFrameCount = TPCircularBufferPeek(&source->buffer, &audioTimestamp, &source->audioDescription);
            sourceTimestamp = audioTimestamp.mHostTime;
        }
        
        if ( sourceFrameCount > sliceFrameCount ) sourceFrameCount = sliceFrameCount;
    }
    
    *ioLengthInFrames = MIN(*ioLengthInFrames, sliceFrameCount);
    
    if ( sourceFrameCount > 0 ) {
        int paddingFrames = 0;
        void *savedmData[2] = { bufferList ? bufferList->mBuffers[0].mData : NULL, bufferList && bufferList->mNumberBuffers == 2 ? bufferList->mBuffers[1].mData : NULL };
        if ( sourceTimestamp > sliceTimestamp + (kSourceTimestampThreshold*__secondsToHostTicks) ) {
            // This source is ahead. We'll pad with silence
            paddingFrames = (sourceTimestamp - sliceTimestamp) * __hostTicksToSeconds * source->audioDescription.mSampleRate;
            if ( paddingFrames > *ioLengthInFrames ) paddingFrames = *ioLengthInFrames;
            
            if ( bufferList ) {
                // Pad
                for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                    memset(bufferList->mBuffers[i].mData, 0, paddingFrames * source->audioDescription.mBytesPerFrame);
                }
                // Point buffers to space after padding
                for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                    bufferList->mBuffers[i].mData = ((uint8_t*)bufferList->mBuffers[i].mData) + paddingFrames * source->audioDescription.mBytesPerFrame;
                }
            }
        }
        
        // Consume the audio
        if ( paddingFrames < *ioLengthInFrames ) {
            UInt32 frames = *ioLengthInFrames - paddingFrames;
            
            // Consume audio
            if ( source->renderCallback ) {
                source->renderCallback(source->source, frames, bufferList, source->callbackUserinfo);
            } else {
                TPCircularBufferConsumeBufferListFrames(&source->buffer, &frames, bufferList, NULL, &source->audioDescription);
            }
            
            *ioLengthInFrames = frames + paddingFrames;
            
            if ( paddingFrames > 0 && bufferList ) {
                // Restore buffers
                for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                    bufferList->mBuffers[i].mData = savedmData[i];
                    bufferList->mBuffers[i].mDataByteSize = *ioLengthInFrames * source->audioDescription.mBytesPerFrame;
                }
            }
        }
    }
    
    // Mark this source as processed for the current time interval
    source->processedForCurrentTimeSlice = YES;
    
    // Determine if we've processed all sources for the current interval
    BOOL allSourcesProcessedForCurrentTimeSlice = YES;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source && !THIS->_table[i].processedForCurrentTimeSlice ) {
            allSourcesProcessedForCurrentTimeSlice = NO;
            break;
        }
    }
    
    if ( allSourcesProcessedForCurrentTimeSlice ) {
        // Reset time slice info
        THIS->_currentSliceFrameCount = 0;
        THIS->_currentSliceTimestamp = 0;
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) THIS->_table[i].processedForCurrentTimeSlice = NO;
        }
    }
}

UInt32 AEMixerBufferPeek(AEMixerBuffer *THIS, uint64_t *outNextTimestamp) {
    uint64_t now = 0;
    
    // Make sure we have at least one source
    BOOL hasSources = NO;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) {
            hasSources = YES;
            break;
        }
    }
    
    if ( !hasSources ) {
        if ( outNextTimestamp ) *outNextTimestamp = 0;
        return 0;
    }
    
    // Determine lowest buffer fill count, excluding drained sources that we aren't receiving from (for those, we'll return silence),
    // and address sources that are behind the timeline
    uint64_t earliestEndTimestamp = UINT64_MAX;
    uint64_t earliestStartTimestamp = UINT64_MAX;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) {
            source_t *source = &THIS->_table[i];
            
            uint64_t timestamp = 0;
            UInt32 frameCount = 0;
            
            if ( source->peekCallback ) {
                frameCount = source->peekCallback(source->source, &timestamp, source->callbackUserinfo);
            } else {
                AudioTimeStamp audioTimestamp;
                frameCount = TPCircularBufferPeek(&source->buffer, &audioTimestamp, &source->audioDescription);
                timestamp = audioTimestamp.mHostTime;
            }
            
            if ( frameCount == 0 ) {
                if ( !now ) now = mach_absolute_time();
                if ( (now - source->lastAudioTimestamp) > (kSourceTimestampIdleThreshold*__secondsToHostTicks) ) {
                    // Not receiving audio - ignore this empty source
                    continue;
                }
                
                // This source is empty
                if ( outNextTimestamp ) *outNextTimestamp = 0;
                return 0;
            } else {
                if ( !now ) now = mach_absolute_time();
                source->lastAudioTimestamp = now;
            }
            
            uint64_t endTimestamp = timestamp + (((double)frameCount / source->audioDescription.mSampleRate) * __secondsToHostTicks);
            
            if ( timestamp < earliestStartTimestamp ) earliestStartTimestamp = timestamp;
            if ( endTimestamp < earliestEndTimestamp ) earliestEndTimestamp = endTimestamp;
        }
    }
    
    if ( earliestStartTimestamp == UINT64_MAX ) {
        // No sources at the moment
        if ( outNextTimestamp ) *outNextTimestamp = 0;
        return 0;
    }
    
    UInt32 frameCount = round((earliestEndTimestamp - earliestStartTimestamp) * __hostTicksToSeconds * THIS->_clientFormat.mSampleRate);
    
    if ( outNextTimestamp ) *outNextTimestamp = earliestStartTimestamp;
    return frameCount;
}

- (void)setAudioDescription:(AudioStreamBasicDescription*)audioDescription forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, NULL);
    }
    
    source->audioDescription = *audioDescription;
    
    // Set input stream format
    checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, index, &source->audioDescription, sizeof(source->audioDescription)),
                "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
}

- (void)setVolume:(float)volume forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, NULL);
    }
    
    source->volume = volume;
    
    // Set volume
    AudioUnitParameterValue value = source->volume;
    checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0),
                "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");

}

- (float)volumeForSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return 0.0;
    return source->volume;
}

- (void)setPan:(float)pan forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, NULL);
    }
    
    source->pan = pan;
    
    // Set pan
    AudioUnitParameterValue value = source->pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0),
                "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

- (float)panForSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return 0.0;
    return source->pan;
}

- (void)unregisterSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return;
    
    source->source = NULL;
    
    [self refreshMixingGraph];
    
    // Wait a little longer for good measure - it's not made clear in the documentation 
    // whether after a synchronous AUGraphUpdate, it's guaranteed that the Core Audio thread
    // is out of the render routine. So, wait to be sure.
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];

    if ( !source->renderCallback ) {
        TPCircularBufferCleanup(&source->buffer);
    }
    memset(source, 0, sizeof(source_t));
}

static OSStatus sourceInputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEMixerBuffer *THIS = (AEMixerBuffer*)inRefCon;
    
    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
        memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    
    source_t *source = &THIS->_table[inBusNumber];
    
    if ( source->source ) {
        AEMixerBufferDequeueSingleSource(THIS, source->source, ioData, &inNumberFrames);
    }
    
    return noErr;
}

- (void)refreshMixingGraph {
    if ( !_graph ) {
        [self createMixingGraph];
    }
    
    // Set bus count
	UInt32 busCount = 0;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source ) busCount++;
    }
    
    if ( !checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each bus
    for ( int busNumber=0; busNumber<busCount; busNumber++ ) {
        source_t *source = &_table[busNumber];
        
        // Set input stream format
        checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, busNumber, &source->audioDescription, sizeof(source->audioDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        // Set volume
        AudioUnitParameterValue value = source->volume;
        checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busNumber, value, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        
        // Set pan
        value = source->pan;
        if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
        if ( value == 1.0 ) value = 0.999;
        checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, busNumber, value, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
        
        // Set the render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &sourceInputCallback;
        rcbs.inputProcRefCon = self;
        OSStatus result = AUGraphSetNodeInputCallback(_graph, _mixerNode, busNumber, &rcbs);
        if ( result != kAUGraphErr_InvalidConnection /* Ignore this error */ )
            checkResult(result, "AUGraphSetNodeInputCallback");
    }
    
    Boolean isInited = false;
    AUGraphIsInitialized(_graph, &isInited);
    if ( !isInited ) {
        checkResult(AUGraphInitialize(_graph), "AUGraphInitialize");
        
        OSMemoryBarrier();
        _graphReady = YES;
    } else {
        for ( int retries=3; retries > 0; retries-- ) {
            Boolean isUpdated = false;
            if ( checkResult(AUGraphUpdate(_graph, &isUpdated), "AUGraphUpdate") ) {
                break;
            }
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
}

- (void)createMixingGraph {
    // Create a new AUGraph
	OSStatus result = NewAUGraph(&_graph);
    if ( !checkResult(result, "NewAUGraph") ) return;
    
    // Multichannel mixer unit
    AudioComponentDescription mixer_desc = {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_MultiChannelMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // Add mixer node to graph
    result = AUGraphAddNode(_graph, &mixer_desc, &_mixerNode );
    if ( !checkResult(result, "AUGraphAddNode mixer") ) return;
    
    // Open the graph - AudioUnits are open but not initialized (no resource allocation occurs here)
	result = AUGraphOpen(_graph);
	if ( !checkResult(result, "AUGraphOpen") ) return;
    
    // Get reference to the audio unit
    result = AUGraphNodeInfo(_graph, _mixerNode, NULL, &_mixerUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return;
    
    // Try to set mixer's output stream format to our client format
    result = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_clientFormat, sizeof(_clientFormat));
    
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The mixer only supports a subset of formats. If it doesn't support this one, then we'll convert manually
        
        // Get the existing format, and apply just the sample rate
        UInt32 size = sizeof(_mixerOutputFormat);
        checkResult(AudioUnitGetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, &size),
                    "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        _mixerOutputFormat.mSampleRate = _clientFormat.mSampleRate;
        
        checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, sizeof(_mixerOutputFormat)), 
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");

        // Create the audio converter
        checkResult(AudioConverterNew(&_mixerOutputFormat, &_clientFormat, &_audioConverter), "AudioConverterNew");
        TPCircularBufferInit(&_audioConverterBuffer, kConversionBufferLength);
    } else {
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    }
}

- (void)pollActionBuffer {
    while ( 1 ) {
        int32_t availableBytes;
        action_t *action = TPCircularBufferTail(&_mainThreadActionBuffer, &availableBytes);
        if ( !action ) break;
        action->action(self, action->userInfo);
        TPCircularBufferConsume(&_mainThreadActionBuffer, sizeof(action_t));
    }
}

static inline source_t *sourceWithID(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, int *index) {
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source == sourceID ) {
            if ( index ) *index = i;
            return &THIS->_table[i];
        }
    }
    return NULL;
}

static void prepareNewSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID) {
    if ( sourceWithID(THIS, sourceID, NULL) ) return;
    
    source_t *source = sourceWithID(THIS, NULL, NULL);
    if ( !source ) return;
    
    memset(source, 0, sizeof(source_t));
    source->source = sourceID;
    source->volume = 1.0;
    source->pan = 0.0;
    source->audioDescription = THIS->_clientFormat;
    
    TPCircularBufferInit(&source->buffer, kSourceBufferLength);
    
    OSMemoryBarrier();
    [THIS refreshMixingGraph];
}

@end


@implementation AEMixerBufferProxy
- (id)initWithMixerBuffer:(AEMixerBuffer*)mixerBuffer {
    _mixerBuffer = mixerBuffer;
    return self;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_mixerBuffer methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation setTarget:_mixerBuffer];
    [invocation invoke];
}
@end