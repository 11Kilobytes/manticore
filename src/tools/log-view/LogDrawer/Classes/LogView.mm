/** \file  LogView.m
 * \author Korei Klein
 * \date 7/7/09
 *
 */

#import "Utils.h"
#import "LogView.h"
#import "VProc.h"
#import "log-desc.hxx"
#import "CustomSplitView.h"
#import "Exceptions.h"


#define DEFAULT_LOG_VIEW_WIDTH ( 5000 )
#define MIN_BAND_HEIGHT ( 200 )
#define SINGLETON_COLOR ( [NSColor yellowColor] )
#define LOG_VIEW_BACKGROUND_COLOR ( [NSColor blackColor] )
#define DEFAULT_TIME_TICK ( 55 )
#define TICK_LINE_COLOR ( [NSColor cyanColor] )
#define TICK_LINE_WIDTH ( 0.02 )

@implementation LogView

- (BOOL)isOpaque
{
    return NO;
}


@synthesize scrollView;
@synthesize timeTick;

- (id)initWithFrame:(NSRect)frame
{
 
    if (![super initWithFrame:frame]) return nil;
    /*
    NSRect f = [self frame];
	f.size.width = DEFAULT_LOG_VIEW_WIDTH;
	f.size.height = self.superview.bounds.size.height;
	[self setFrame:f];
	splitView = [[CustomSplitView alloc] initWithFrame:self.bounds];
	messageView = [[MessageView alloc] initWithFrame:self.bounds];
	[self addSubview:splitView];
	NSRect splitViewBounds = splitView.bounds;
	splitViewBounds.size.height -= 2 * DIVIDER_THICKNESS;
	splitViewBounds.origin.y += DIVIDER_THICKNESS;
	splitView.bounds = splitViewBounds;
	[self addSubview:messageView];
*/
    timeTick = DEFAULT_TIME_TICK;


	
    return self;
}


- (void)drawRect:(NSRect)rect
{
    // Draw Background
    [LOG_VIEW_BACKGROUND_COLOR set];
    [NSBezierPath fillRect:[self bounds]];
    
    

    // Draw tick lines
    NSBezierPath *verticalLine = [[NSBezierPath alloc] init];
    NSRect shapeBounds = splitView.shapeBounds;
    NSRect bounds = self.bounds;
    
    NSPoint s = NSMakePoint(shapeBounds.origin.x, bounds.origin.y);
    NSPoint f = NSMakePoint(shapeBounds.origin.x, bounds.origin.y + bounds.size.height);
    
    [TICK_LINE_COLOR set];
    [verticalLine setLineWidth:TICK_LINE_WIDTH];

    while (s.x < bounds.origin.x + bounds.size.width)
    {

	[verticalLine moveToPoint:s];
	[verticalLine lineToPoint:f];
	[verticalLine stroke];
	s.x += timeTick;
	f.x += timeTick;
    }

}

- (void)awakeFromNib
{

}


int sillyNumber = 0;

/// For Testing, return a new interesting color
- (NSColor *)sillyNextColor
{
    if (sillyNumber == 0)
    {
	sillyNumber = 1;
	return [NSColor redColor];
    }
    else {
	sillyNumber = 0;
	return [NSColor blackColor];
    }
}


/// FIXME pick better colors
- (NSColor *)colorForIntervalGroup:(IntervalGroup *)g
{
    return [NSColor blueColor];
}
/// Return the color that a state should be drawn in
- (NSColor *)colorForState:(int)state
{
    switch (state)
    {
	case 0:
	    return [NSColor greenColor];
	case 1:
	    return [NSColor redColor];
	case 2:
	    return [NSColor grayColor];
	case 3:
	    return [NSColor orangeColor];
	case 4:
	    return [NSColor purpleColor];
	case 5:
	    return [NSColor blueColor];
	case 6:
	    return [NSColor brownColor];
	default:
	    [Exceptions raise:@"Can't decide on a color for state"];
    }
    return nil;
}



- (void)displayInterval:(struct LogInterval *)logInterval
	    atZoomLevel:(enum ZoomLevel)zoomLevel
	    fromLogData:(LogData *)logData
	     filteredBy:(GroupFilter *)filter;
{
<<<<<<< .mine
=======
    logFile = (LogFile *) lf;
>>>>>>> .r4014
    NSRect bounds = [self bounds];
    CGFloat min_height = 
	logData.nVProcs * (MIN_BAND_HEIGHT + [splitView dividerThickness]);
    NSLog(@"min height = %f, nVProcs = %d", min_height, logFile.nVProcs);
    if (bounds.size.height < min_height)
    {
	bounds.size.height = min_height;
    }
    CGFloat band_height =
	(bounds.size.height - logFile.nVProcs * splitView.dividerThickness) /
		logFile.nVProcs;
    NSRect frame = self.frame;
    frame.size.width = bounds.size.width;
    frame.size.height = bounds.size.height;
    // NSLog(@"Setting logview frame to %f,%f,%f,%f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    self.frame = frame;
    self.bounds = bounds;
    
 
    // The old subviews no longer have valid shapes on them, remove them
    NSRect splitViewBounds = bounds;
    splitViewBounds.origin.y += DIVIDER_THICKNESS;
    splitViewBounds.size.height -= 2 * DIVIDER_THICKNESS;
    CustomSplitView *newSplitView = [[CustomSplitView alloc] initWithFrame:splitViewBounds];
    MessageView *newMessageView = [[MessageView alloc] initWithFrame:bounds];
    [self replaceSubview:splitView with:newSplitView];
    [self replaceSubview:messageView with:newMessageView];
    splitView = newSplitView;
    messageView = newMessageView;

   
    int v = 0;
    for (VProc *vp in logFile.vProcs)
    {
	DynamicEvent *events = (DynamicEvent *) vp.events;
	NSRect curFrame = NSMakeRect(splitViewBounds.origin.x, v * band_height,
				     splitViewBounds.size.width, band_height);
        BandView *band = [[BandView alloc] initWithFrame:curFrame];
	band.selectedEvent = selectedEvent;
	NSRect bandBounds = band.shapeBounds;

	// Converts from intervals in log file to intervals in log view
	double scale = bandBounds.size.width / logWidth;

	
	NSRect splitViewFrame = [splitView frame];
	// NSLog(@"adding a band for VProc with vpId %d", v);


	for (int i = 0; i < vp.numEvents; ++i)
	{
	    // NSLog(@"checking if event %d of %d is in timespan", i, vp.numEvents);
	    EventDesc *eventDesc = dynamicEventDescription(events[i], nil);
	    if (eventDesc)
	    {
		// NSLog(@"Loaded eventDesc with description %s", eventDesc->Description());
	    }
	    else
	    {
		NSLog(@"Could not load event desc");
	    }
	    if (events[i].timestamp >= logX &&
	        events[i].timestamp <= logX + logWidth)
	    {
		// NSLog(@"Found event in timespan, checking for shapes to draw");
		
		
		

		
		
		
		CGFloat drawingPosition =
		    bandBounds.origin.x + scale * (events[i].timestamp - logX);		
#pragma mark SINGLETONS
	/////////////// SINGLETONS ///////////////////

		// FIXME makes only singletons happen
		if (events[i].desc->isSimpleEvent())
		{
		    // NSLog(@"adding singleton");
		    // The event is a singleton
		    // The event may also be in some groups
		    [band addSingleton:&events[i]
			     withColor:SINGLETON_COLOR
			      andStart:drawingPosition];
		}
		
		// Convert this event into a shape, once for each group it is in
		
	/////////////// STATE GROUPS ///////////////////
#pragma mark STATE GROUPS
		
		// For now, we set the stateGroup to be the one containing
		// the first event, if such a state exists
		
		if (!stateGroup)
		{
		    // NSLog(@"stateGroup is uninitialized, checking event for groups to use");
		    // NSLog(@"logFile.desc = 0x%x", logFile.desc);
		    std::vector<StateGroup *> *states =
			logFile.desc->StateGroups(eventDesc);
		    if (states)
		    {
			if (states->size() >=1)
			{
			    stateGroup = states->at(0);
			    NSLog(@"Initializing stateGroup to %s", stateGroup->Desc());
			    [band setStateStartColor:
			       [self colorForState:stateGroup->StartState()]];
			}
		    }
		}
		
		// Warning, NOT an ELSE clause!! must be an if. see logic above.
		if (stateGroup && [filter enabled:stateGroup] != 0)
		{
		    // This function returns -1 if this event does not mark
		    // a transition in this state
		    int next_state = stateGroup->NextState(cur_state, eventDesc);
		    if (next_state != -1)
		    {
			[band addState:&events[i]
			     withColor:[self colorForState:next_state]
			      andStart:drawingPosition];
		    }
		    else
		    {
			// This event is not a transition in this state,
			// therefore it defines no shape.
			// Do nothing.
		    }
		}
#pragma mark INTERVAL GROUPS
	/////////////// INTERVAL GROUPS ///////////////////
		std::vector<IntervalGroup *> *intervals =
		    logFile.desc->IntervalGroups(eventDesc);
		if (intervals)
		{
		    for (int h = 0; h < intervals->size(); ++h)
		    {
			// NSLog(@"checking interval %s", intervals->at(h)->Desc());
		        IntervalGroup *intervalGroup = intervals->at(h);
			if ([filter enabled:intervalGroup].intValue == 0) continue;
			
		        if (eventDesc == intervalGroup->Start())
		        {
		    	[band addIntervalStart:&events[i]
		    		  withColor:[self colorForIntervalGroup:intervalGroup]
		    	   forIntervalGroup:intervalGroup
		    		   andStart:drawingPosition];
		        }
		        else
		        {
			    assert (eventDesc == intervalGroup->End());
			    [band addIntervalEnd:&events[i]
				forIntervalGroup:intervalGroup
					andStart:drawingPosition];
		        }
		    }
		}
		
		
#pragma mark DEPENDENT GROUPS
	///////////////// DEPENDENT GROUPS ////////////////
		
		std::vector<DependentGroup *> *dependents =
		    logFile.desc->DependentGroups(eventDesc);
		if (dependents)
		{
		    for (int h = 0; h < dependents->size(); ++h)
		    {
			NSLog(@"checking dependents");
			DependentGroup *dependentGroup = dependents->at(h);
			if ([filter enabled:dependentGroup].intValue == 0) continue;
			
			if (eventDesc == dependentGroup->Src())
			{
			    // 
			}
			else
			{
			    assert (eventDesc == dependentGroup->Dst());
			}
		    }
		}
		/* NSLog(@"\tAdding event at time %qu, position %f to band", events[i].timestamp, drawingPosition);
		[band addState:&events[i] withColor:[self sillyNextColor]
		      andStart:drawingPosition];
		 */
	    }
	    else {
		// The event is not part of the current timespan
		// NSLog(@"Skipping event at time %qu, because it is out of timespan", events[i].timestamp);
	    }
	}
	
	//////////////////////// FINISH ///////////////////
	[splitView addSubview:band];
	[band setNeedsDisplay:YES];
	++v;
    }
    
    [splitView adjustSubviews];
    [self setNeedsDisplay:YES];
    [messageView setNeedsDisplay:YES];
    [splitView setNeedsDisplay:YES];
}





@end