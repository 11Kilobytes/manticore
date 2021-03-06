/** \file  MessageView.h
 * \author Korei Klein
 * \date 7/7/09
 */


#import <Cocoa/Cocoa.h>
#import "LogDoc.h"

@class Message;


/// Draws message arrows and other foreground events
/** The MessageView will be placed on top of the BandViews in a LogView.
 This way, it will be able to draw shapes that appear on top of all the bands.
 Currently, it is usefull for drawing message arrows.
 It may need to draw more foreground shapes later.
 */
@interface MessageView : NSView {
    NSMutableArray *times; // NSNumbers of floats of when to print the corresponding time value
    NSMutableArray *timeValues; // NSString *s that must be printed in accordance with tick lines
    NSMutableDictionary *timeValueAttributes;

    IBOutlet LogDoc *logDoc;

    NSMutableArray *dependents;
}

- (MessageView *)initWithFrame:(NSRect)frame;


- (void)updateDependents:(NSArray *)dependentsVal;


- (BOOL)bandReceivedEvent:(NSEvent *)e;

// - (void)displayTime:(uint64_t)t atPosition:(CGFloat)f;

@end
