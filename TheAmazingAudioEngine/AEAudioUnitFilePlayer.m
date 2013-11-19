//
//  AEAudioUnitFilePlayer.m
//  TheAmazingAudioEngine
//
//  Created by Aran Mulholland on 19/11/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import "AEAudioUnitFilePlayer.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}

static inline void ResetFormat(AudioStreamBasicDescription *ioDescription) {
    ioDescription->mSampleRate = 0;
    ioDescription->mFormatID = 0;
    ioDescription->mBytesPerPacket = 0;
    ioDescription->mFramesPerPacket = 0;
    ioDescription->mBytesPerFrame = 0;
    ioDescription->mChannelsPerFrame = 0;
    ioDescription->mBitsPerChannel = 0;
    ioDescription->mFormatFlags = 0;
}

@implementation AEAudioUnitFilePlayer

- (id)initAudioUnitFilePlayerWithAudioController:(AEAudioController *)audioController
                                           error:(NSError **)error {

    if (self = [super initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer)
                                   audioController:audioController
                                             error:error]) {
        [audioController addTimingReceiver:self];
        filePlayerUnit_ = self.audioUnit;
    }



    return self;
}

- (id)initAudioUnitFilePlayerWithAudioController:(AEAudioController *)audioController
                              preInitializeBlock:(void (^)(AudioUnit audioUnit))block
                                           error:(NSError **)error {

    if (self = [super initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer)
                                   audioController:audioController
                                preInitializeBlock:block
                                             error:error]) {
        [audioController addTimingReceiver:self];
    }
    return self;
}

#pragma mark - File Management

-(OSStatus)openAudioFile:(NSURL *)fileUrl {
    OSStatus err = AudioFileOpenURL ((CFURLRef)fileUrl, kAudioFileReadPermission, 0, &audioFile);

    if (err != noErr){
        //close it there is something wrong
        AudioFileClose (audioFile);
        return err;
    }

    // get the data format
    UInt32 propertySize = sizeof(AudioStreamBasicDescription);
    //reset the format
    ResetFormat(&fileFormat);

    err = AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &propertySize, &fileFormat);
    if (err != noErr){
        AudioFileClose (audioFile);
        return err;
    }

    //get the file size
    propertySize = sizeof(UInt64);
    err = AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataPacketCount, &propertySize, &numberOfPackets);
    if (err != noErr){
        AudioFileClose (audioFile);
        return err;
    }

    fileDuration = (numberOfPackets * fileFormat.mFramesPerPacket);// / fileFormat.mSampleRate;

    return noErr;
}

- (OSStatus)prepareAudioFile {
    //setup a region to play the whole file
    ScheduledAudioFileRegion rgn;
    memset (&rgn.mTimeStamp, 0, sizeof(rgn.mTimeStamp));
    rgn.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    rgn.mTimeStamp.mSampleTime = 0;
    rgn.mCompletionProc = NULL;
    rgn.mCompletionProcUserData = NULL;
    rgn.mAudioFile = audioFile;
    rgn.mLoopCount = 999;
    rgn.mStartFrame = 0;
    rgn.mFramesToPlay = (UInt32)(numberOfPackets * fileFormat.mFramesPerPacket);

    OSStatus err = AudioUnitSetProperty(filePlayerUnit_, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &audioFile, sizeof(AudioFileID));

    if (err != noErr){
        printf("Cannot schedule files to be played");
        AudioFileClose (audioFile);
        return err;
    }

    err = AudioUnitSetProperty(filePlayerUnit_, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &rgn, sizeof(rgn));

    if (err != noErr){
        printf("Cannot schedule file region");
        AudioFileClose (audioFile);
        return err;
    }

    // prime the fp AU with default values
    UInt32 defaultVal = 0;
    err = AudioUnitSetProperty(filePlayerUnit_, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &defaultVal, sizeof(defaultVal));

    if (err != noErr){
        printf("Cannot prime file player unit");
        AudioFileClose (audioFile);
        return err;
    }

    if (err == noErr){
        fileIsValid = YES;
    }
    
    return err;

}

- (OSStatus)closeAudioFile {
    AudioUnitReset(filePlayerUnit_, kAudioUnitScope_Global, 0);
    AudioFileClose(audioFile);

    return noErr;
}


- (void)loadAudioFileFromUrl:(NSURL *)fileUrl {

    checkResult([self closeAudioFile], "Closing previous audio file");

    // workaround for a race condition in the file player AU
    usleep (10 * 1000);

    fileIsValid = NO;

    checkResult([self openAudioFile:fileUrl], "Opening audio file");
    checkResult([self prepareAudioFile], "Preparing audio file for playback");
}


#pragma mark - Transport

- (BOOL)play{
    if (fileIsValid == NO){
        return NO;
    }
    else{
        // tell the file Player Unit AU when to start playing -1 means next render cycle
        AudioTimeStamp startTime;
        memset (&startTime, 0, sizeof(startTime));
        startTime.mFlags = kAudioTimeStampSampleTimeValid;
        startTime.mSampleTime = -1;

        return checkResult(AudioUnitSetProperty(filePlayerUnit_, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime)), "Starting playback on the file player audio unit");
    }
}

- (BOOL)stop{
    return checkResult(AudioUnitReset(filePlayerUnit_, kAudioUnitScope_Global, 0), "Resetting audio file player unit in order to stop playback");
}

#pragma mark - AEAudioTimingReceiver Protocol

static void timingReceiver(id receiver, AEAudioController *audioController, const AudioTimeStamp *time, UInt32 const frames, AEAudioTimingContext context) {
    AEAudioUnitFilePlayer *audioUnitFilePlayer = receiver;

    if (context == AEAudioTimingContextOutput) {
        //this is the pre-render callback. Here we can determine if
        //the audio file player will stop playing during this round of playback.

    }
}

-(AEAudioControllerTimingCallback)timingReceiverCallback {
    return timingReceiver;
}

@end
