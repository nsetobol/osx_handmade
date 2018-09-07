///////////////////////////////////////////////////////////////////////
// osx_main.mm
//
// Jeff Buck
// Copyright 2014-2016. All Rights Reserved.
//

#include <Cocoa/Cocoa.h>

#define GL_GLEXT_LEGACY
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>

#include <mach/mach_time.h>
#include <dlfcn.h>

#define Maximum(A, B) ((A > B) ? (A) : (B))

#define FormatString(Size, Dest, ...) snprintf(Dest, Size, __VA_ARGS__)
#define S32FromZ(String) atoi(String)
#define MemoryIsEqual(Size, A, B) (memcmp(A, B, Size) == 0)
#define IsWhitespace(A) isspace(A)

#include "handmade_types.h"


internal b32x StringsAreEqual(char *A, char *B) {return(strcmp(A, B) == 0);}
internal b32x StringsAreEqual(umm Count, char *A, char *B) {return(strncmp(A, B, Count) == 0);}

#import "handmade_intrinsics.h"
#import "handmade_math.h"
#import "handmade_renderer.h"
#import "handmade_renderer_opengl.h"

global open_gl OpenGL;

#import "osx_handmade_events.h"
#import "osx_handmade_debug.cpp"
#import "osx_handmade_opengl.cpp"
#import "handmade_renderer_opengl.cpp"
#import "handmade_renderer.cpp"

global b32x GlobalRunning;

// Let the command line override
#ifndef HANDMADE_USE_VSYNC
#define HANDMADE_USE_VSYNC 1
#endif

global NSOpenGLContext* GlobalGLContext;
global r32 GlobalAspectRatio;

const r32 GlobalRenderWidth = 960;
const r32 GlobalRenderHeight = 540;

void* OSXAllocateMemory(umm size)
{
	void* p = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);

	if (p == MAP_FAILED)
	{
		printf("OSXAllocateMemory: mmap error: %d: %s\n", errno, strerror(errno));
	}

	return p;
}

#pragma pack(push, 1)
struct bitmap_header
{
	u16 FileType;
	u32 FileSize;
	u16 Reserved1;
	u16 Reserved2;
	u32 BitmapOffset;
	u32 Size;
	s32 Width;
	s32 Height;
	u16 Planes;
	u16 BitsPerPixel;
	u32 Compression;
	u32 SizeOfBitmap;
	s32 HorzResolution;
	s32 VertResolution;
	u32 ColorsUsed;
	u32 ColorsImportant;

	u32 RedMask;
	u32 GreenMask;
	u32 BlueMask;
};
#pragma pack(pop)

struct loaded_bitmap
{
	void *Memory;
	s32 Width;
	s32 Height;
	s32 Pitch;
};

struct entire_file
{
	u32 ContentsSize;
	void *Contents;
};

entire_file
ReadEntireFile(char *FileName)
{
	entire_file Result = {};

	FILE *In = fopen(FileName, "rb");

	if(In)
	{
		fseek(In, 0, SEEK_END);
		Result.ContentsSize = ftell(In);
		fseek(In, 0, SEEK_SET);

		Result.Contents = OSXAllocateMemory(Result.ContentsSize);
		fread(Result.Contents, Result.ContentsSize, 1, In);
		fclose(In);
	}
	else
	{
		printf("ERROR: Cannot open file %s.\n", FileName);
	}

	return Result;
}


internal renderer_texture LoadBMP(char *FileName)
{
	loaded_bitmap Result = {};

	entire_file ReadResult = ReadEntireFile(FileName);

	if(ReadResult.ContentsSize != 0)
	{
		bitmap_header *Header = (bitmap_header *)ReadResult.Contents;
		uint32 *Pixels = (uint32 *)((uint8 *)ReadResult.Contents + Header->BitmapOffset);
		Result.Memory = Pixels;
		Result.Width = Header->Width;
		Result.Height = Header->Height;

		Assert(Result.Height >= 0);
		Assert(Header->Compression == 3);

		// NOTE(casey): If you are using this generically for some reason,
		// please remember that BMP files CAN GO IN EITHER DIRECTION and
		// the height will be negative for top-down.
		// (Also, there can be compression, etc., etc... DON'T think this
		// is complete BMP loading code because it isn't!!)

		// NOTE(casey): Byte order in memory is determined by the Header itself,
		// so we have to read out the masks and convert the pixels ourselves.
		uint32 RedMask = Header->RedMask;
		uint32 GreenMask = Header->GreenMask;
		uint32 BlueMask = Header->BlueMask;
		uint32 AlphaMask = ~(RedMask | GreenMask | BlueMask);

		bit_scan_result RedScan = FindLeastSignificantSetBit(RedMask);
		bit_scan_result GreenScan = FindLeastSignificantSetBit(GreenMask);
		bit_scan_result BlueScan = FindLeastSignificantSetBit(BlueMask);
		bit_scan_result AlphaScan = FindLeastSignificantSetBit(AlphaMask);

		Assert(RedScan.Found);
		Assert(GreenScan.Found);
		Assert(BlueScan.Found);
		Assert(AlphaScan.Found);

		int32 RedShiftDown   = (int32)RedScan.Index;
		int32 GreenShiftDown = (int32)GreenScan.Index;
		int32 BlueShiftDown  = (int32)BlueScan.Index;
		int32 AlphaShiftDown = (int32)AlphaScan.Index;

		uint32* SourceDest = Pixels;

		for(int32 Y = 0; Y < Header->Height; ++Y)
		{
			for(int32 X = 0; X < Header->Width; ++X)
			{
				uint32 C = *SourceDest;

				v4 Texel = {(real32)((C & RedMask)   >> RedShiftDown),
							(real32)((C & GreenMask) >> GreenShiftDown),
							(real32)((C & BlueMask)  >> BlueShiftDown),
							(real32)((C & AlphaMask) >> AlphaShiftDown)};

				Texel = SRGB255ToLinear1(Texel);
#if 1
				Texel.rgb *= Texel.a;
#endif
				Texel = Linear1ToSRGB255(Texel);

				*SourceDest++ = (((uint32)(Texel.a + 0.5f) << 24) |
							 ((uint32)(Texel.r + 0.5f) << 16) |
							 ((uint32)(Texel.g + 0.5f) << 8) |
							 ((uint32)(Texel.b + 0.5f) << 0));
			}
		}
	}

	Result.Pitch = Result.Width*4;

	renderer_texture CubeTexture = {};
	texture_op CubeOp = {};
	CubeOp.IsAllocate = true;
	CubeOp.Allocate.Width = Result.Width;
	CubeOp.Allocate.Height = Result.Height;
	CubeOp.Allocate.Data = Result.Memory;
	CubeOp.Allocate.ResultTexture = &CubeTexture;
	AddOp(&OpenGL.TextureQueue, &CubeOp);
	OpenGLManageTextures();

	return CubeTexture;
}


///////////////////////////////////////////////////////////////////////
// Application Delegate

@interface HandmadeAppDelegate : NSObject<NSApplicationDelegate, NSWindowDelegate>
@end

@implementation HandmadeAppDelegate

// app delegate methods
- (void)applicationDidFinishLaunching:(id)sender
{
	#pragma unused(sender)
}


- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
	#pragma unused(sender)

	return YES;
}


- (void)applicationWillTerminate:(NSApplication*)sender
{
	#pragma unused(sender)
}


// window delegate methods
- (NSSize)windowWillResize:(NSWindow*)window
                    toSize:(NSSize)frameSize
{
	// Maintain the proper aspect ratio...
	//frameSize.height = frameSize.width / GlobalAspectRatio;

	NSRect WindowRect = [window frame];
	NSRect ContentRect = [window contentRectForFrameRect:WindowRect];

	r32 WidthAdd = (WindowRect.size.width - ContentRect.size.width);
	r32 HeightAdd = (WindowRect.size.height - ContentRect.size.height);

	r32 NewCy = (GlobalRenderHeight * (frameSize.width - WidthAdd)) / GlobalRenderWidth;

	frameSize.height = NewCy + HeightAdd;

	return frameSize;
}

- (void)windowWillClose:(id)sender
{
	GlobalRunning = false;
}

@end

// Application Delegate
///////////////////////////////////////////////////////////////////////


void OSXCreateMainMenu()
{
    NSMenu* menubar = [NSMenu new];

	NSMenuItem* appMenuItem = [NSMenuItem new];
	[menubar addItem:appMenuItem];

	[NSApp setMainMenu:menubar];

	NSMenu* appMenu = [NSMenu new];

    NSString* appName = @"Handmade Renderer Test";

    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Enter Full Screen"
					  						    action:@selector(toggleFullScreen:)
										 keyEquivalent:@"f"]];

    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:[@"Quit " stringByAppendingString:appName]
											    action:@selector(terminate:)
										 keyEquivalent:@"q"]];
    [appMenuItem setSubmenu:appMenu];
}


void OSXProcessPendingMessages()
{
	NSEvent* Event;

	do
	{
		Event = [NSApp nextEventMatchingMask:NSEventMaskAny
									untilDate:nil
										inMode:NSDefaultRunLoopMode
									dequeue:YES];

		switch ([Event type])
		{
			case NSEventTypeKeyDown:
			case NSEventTypeKeyUp:
			{
				u32 KeyCode = [Event keyCode];
				if (KeyCode == kVK_ANSI_Q)
				{
					GlobalRunning = false;
				}
			} break;

			default:
				[NSApp sendEvent:Event];
		}
	} while (Event != nil);
}



///////////////////////////////////////////////////////////////////////
@interface HandmadeView : NSOpenGLView
{
}
@end

@implementation HandmadeView

- (id)init
{
	self = [super init];

	return self;
}


- (void)prepareOpenGL
{
	[super prepareOpenGL];
	[[self openGLContext] makeCurrentContext];
}

- (void)reshape
{
	[super reshape];

	NSRect bounds = [self bounds];
	[GlobalGLContext makeCurrentContext];
	[GlobalGLContext update];
	glViewport(0, 0, bounds.size.width, bounds.size.height);
}

@end


///////////////////////////////////////////////////////////////////////

enum test_scene_element
{
	Element_Grass,
	Element_Tree,
	Element_Wall,
};

#define TEST_SCENE_DIM_X 40
#define TEST_SCENE_DIM_Y 50

struct test_scene
{
	v3 MinP;
	test_scene_element Elements[TEST_SCENE_DIM_Y][TEST_SCENE_DIM_X];

	renderer_texture GrassTexture;
	renderer_texture WallTexture;
	renderer_texture TreeTexture;
	renderer_texture HeadTexture;
};


internal void PlaceRandom(test_scene* Scene, test_scene_element Element, u32 Count)
{
	u32 Placed = 0;

	while(Placed < Count)
	{
		u32 X = 1 + (rand() % (TEST_SCENE_DIM_X - 1));
		u32 Y = 1 + (rand() % (TEST_SCENE_DIM_Y - 1));

		u32 Occ = 0;

		for(u32 TestY = (Y - 1); TestY <= (Y + 1); ++TestY)
		{
			for(u32 TestX = (X - 1); TestX <= (X + 1); ++TestX)
			{
				if(Scene->Elements[TestY][TestX])
				{
					++Occ;
				}
			}
		}

		if(Occ == 0)
		{
			Scene->Elements[Y][X] = Element;
			++Placed;
		}
	}
}


internal void InitTestScene(test_scene* Scene)
{
	Scene->GrassTexture = LoadBMP("test_cube_grass.bmp");
	Scene->WallTexture = LoadBMP("test_cube_wall.bmp");
	Scene->TreeTexture = LoadBMP("test_sprite_tree.bmp");
	Scene->HeadTexture = LoadBMP("test_sprite_head.bmp");

	Scene->MinP = V3(-0.5f*(f32)TEST_SCENE_DIM_X,
					 -0.5f*(f32)TEST_SCENE_DIM_Y,
					 0.0f);

	PlaceRandom(Scene, Element_Tree, 90);
	PlaceRandom(Scene, Element_Wall, 50);
}


internal void PushSimpleScene(render_group* Group, test_scene* Scene)
{
	srand(1234);

	for(s32 Y = 0; Y < TEST_SCENE_DIM_Y; ++Y)
	{
		for(s32 X = 0; X <= TEST_SCENE_DIM_X; ++X)
		{
			test_scene_element Elem = Scene->Elements[Y][X];

			f32 Z = 0.4f*((f32)rand() / (f32)RAND_MAX);
			f32 R = 0.5f + 0.5f*((f32)rand() / (f32)RAND_MAX);
			f32 ZRadius = 2.0f;
			v4 Color = V4(R, 1, 1, 1);
			v3 P = Scene->MinP + V3((f32)X, (f32)Y, Z);

			PushCube(Group, Scene->GrassTexture, P, V3(0.5f, 0.5f, ZRadius), Color, 0.0f);

			v3 GroundP = P + V3(0, 0, ZRadius);

			if(Elem == Element_Tree)
			{
				PushSprite(Group, Scene->TreeTexture, true, GroundP,
				           V2(2.0f, 2.5f), V2(0, 0), V2(1, 1));
			}
			else if(Elem == Element_Wall)
			{
				f32 WallRadius = 1.0f;

				PushCube(Group, Scene->WallTexture, GroundP + V3(0, 0, WallRadius),
				         V3(0.5f, 0.5f, WallRadius), Color, 0.0f);
			}
		}
	}

	PushSprite(Group, Scene->HeadTexture, true, V3(0, 2.0f, 3.0f),
	           V2(4.0f, 4.0f), V2(0, 0), V2(1, 1));
}


int main(int argc, const char* argv[])
{
	#pragma unused(argc)
	#pragma unused(argv)

	@autoreleasepool
	{
	// Cocoa boilerplate startup code
	NSApplication* app = [NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

	OSXCreateMainMenu();

	// Set working directory
	NSString *dir = [[NSFileManager defaultManager] currentDirectoryPath];
	NSLog(@"working directory: %@", dir);

	NSFileManager* FileManager = [NSFileManager defaultManager];
	NSString* AppPath = [NSString stringWithFormat:@"%@/Contents/Resources",
		[[NSBundle mainBundle] bundlePath]];
	if ([FileManager changeCurrentDirectoryPath:AppPath] == NO)
	{
		Assert(0);
	}

	HandmadeAppDelegate* appDelegate = [[HandmadeAppDelegate alloc] init];
	[app setDelegate:appDelegate];

    [NSApp finishLaunching];


	///////////////////////////////////////////////////////////////////
	// Game Setup
	//
    NSOpenGLPixelFormatAttribute openGLAttributes[] =
    {
        NSOpenGLPFAAccelerated,
#if HANDMADE_USE_VSYNC
        NSOpenGLPFADoubleBuffer, // Uses vsync
#endif
		NSOpenGLPFAColorSize, 24,
		NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        0
    };
	NSOpenGLPixelFormat* PixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:openGLAttributes];
    GlobalGLContext = [[NSOpenGLContext alloc] initWithFormat:PixelFormat shareContext:NULL];

	///////////////////////////////////////////////////////////////////
	// Create the main window and the content view
	NSRect screenRect = [[NSScreen mainScreen] frame];

	int BytesPerPixel = 4;

	GlobalAspectRatio = GlobalRenderWidth / GlobalRenderHeight;

	NSRect InitialFrame = NSMakeRect((screenRect.size.width - GlobalRenderWidth) * 0.5,
									(screenRect.size.height - GlobalRenderHeight) * 0.5,
									GlobalRenderWidth,
									GlobalRenderHeight);

	NSWindow* window = [[NSWindow alloc] initWithContentRect:InitialFrame
									styleMask:NSWindowStyleMaskTitled
												| NSWindowStyleMaskClosable
												| NSWindowStyleMaskMiniaturizable
												| NSWindowStyleMaskResizable
									backing:NSBackingStoreBuffered
									defer:NO];

	[window setBackgroundColor: NSColor.redColor];
	[window setDelegate:appDelegate];

	NSView* cv = [window contentView];
	[cv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[cv setAutoresizesSubviews:YES];

	HandmadeView* GLView = [[HandmadeView alloc] init];
	[GLView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[GLView setPixelFormat:PixelFormat];
	[GLView setOpenGLContext:GlobalGLContext];
	[GLView setFrame:[cv bounds]];

	[cv addSubview:GLView];

    [PixelFormat release];

	[window setMinSize:NSMakeSize(160, 90)];
	[window setTitle:@"Handmade Renderer Test"];
	[window makeKeyAndOrderFront:nil];


	//OSXSetupGameRenderBuffer(&GameData, GlobalRenderWidth, GlobalRenderHeight, BytesPerPixel);


	///////////////////////////////////////////////////////////////////
	// OpenGL setup with Cocoa
#if HANDMADE_USE_VSYNC
    GLint swapInt = 1;
#else
    GLint swapInt = 0;
#endif
	[GlobalGLContext setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];
	[GlobalGLContext setView:[window contentView]];
	[GlobalGLContext makeCurrentContext];


	///////////////////////////////////////////////////////////////////
	// Non-Cocoa OpenGL
	//
	OSXInitOpenGL();


	///////////////////////////////////////////////////////////////////
	// Run loop
	//
	u64 CurrentTime = mach_absolute_time();
	u64 LastCounter = CurrentTime;

#if 1
	u64 tickCounter = 0;
	float frameTime = 0.0f;
#endif

	GlobalRunning = true;

	u32 PushBufferSize = Megabytes(64);
	u8* PushBuffer = (u8*)OSXAllocateMemory(PushBufferSize);

	u32 MaxVertexCount = 65536;
	textured_vertex* VertexArray = (textured_vertex*)OSXAllocateMemory(MaxVertexCount
																	   * sizeof(textured_vertex));
	renderer_texture* BitmapArray = (renderer_texture*)OSXAllocateMemory(MaxVertexCount
	                                                                     * sizeof(renderer_texture));

	u32 TextureOpCount = 1024;
	InitTextureQueue(&OpenGL.TextureQueue,
	                 TextureOpCount,
					 (texture_op*)OSXAllocateMemory(sizeof(texture_op) * TextureOpCount));

	test_scene Scene = {};
	InitTestScene(&Scene);

	f32 CameraPitch = 0.3f*Pi32;
	f32 CameraOrbit = 0;
	f32 CameraDolly = 20.0f;
	f32 CameraDropShift = -1.0f;
	f32 CameraFocalLength = 3.0f;

	f32 NearClipPlane = 0.2f;
	f32 FarClipPlane = 1000.0f;

	f32 tCameraShift = 0.0f;

	f32 MinSPF = F32Max;
	f32 MaxSPF = 0.0f;
	u32 DisplayCounter = 0;

	while (GlobalRunning)
	{
		OSXProcessPendingMessages();

		[GlobalGLContext makeCurrentContext];


		///////////////////////////////////////////////////////////////
		// Main Game Function
		//
		CGRect WindowFrame = [window frame];
		CGRect ContentViewFrame = [[window contentView] frame];

		float DrawWidth = ContentViewFrame.size.width;
		float DrawHeight = ContentViewFrame.size.height;

#if 0
		CGPoint MouseLocationInScreen = [NSEvent mouseLocation];
		BOOL MouseInWindowFlag = NSPointInRect(MouseLocationInScreen, WindowFrame);
		CGPoint MouseLocationInView = {};

		if (MouseInWindowFlag)
		{
			// We don't actually care what the mouse screen coordinates are, we just want the
			// coordinates relative to the content view
			NSRect RectInWindow = [window convertRectFromScreen:NSMakeRect(MouseLocationInScreen.x,
																			MouseLocationInScreen.y,
																			1, 1)];
			NSPoint PointInWindow = RectInWindow.origin;
			MouseLocationInView = [[window contentView] convertPoint:PointInWindow fromView:nil];
		}

		u32 MouseButtonMask = [NSEvent pressedMouseButtons];
#endif

		b32x Fog = false;

		rectangle2i DrawRegion = AspectRatioFit(16, 9, DrawWidth, DrawHeight);
		camera_params Camera = GetStandardCameraParams(GetWidth(DrawRegion), CameraFocalLength);

		if (tCameraShift > Tau32)
		{
			tCameraShift -= Tau32;
		}

		v3 CameraOffset = {0, 0, CameraDropShift};

#if 0
		CameraOffset += 10.0f * V3(cosf(tCameraShift), -0.2f + sinf(tCameraShift), 0.0f);
#else
		CameraOrbit = tCameraShift;
#endif

		game_render_commands RenderCommands = DefaultRenderCommands(
				PushBufferSize, PushBuffer,
				(u32)GetWidth(DrawRegion),
				(u32)GetHeight(DrawRegion),
				MaxVertexCount, VertexArray, BitmapArray,
				OpenGL.WhiteBitmap);

		m4x4 CameraO = ZRotation(CameraOrbit)*XRotation(CameraPitch);
		v3 CameraOt = CameraO*(V3(0, 0, CameraDolly));

		render_group Group = BeginRenderGroup(0, &RenderCommands, 1,
											  GetWidth(DrawRegion),
											  GetHeight(DrawRegion));

		SetCameraTransform(&Group, 0, Camera.FocalLength, GetColumn(CameraO, 0),
						   GetColumn(CameraO, 1),
						   GetColumn(CameraO, 2),
						   CameraOt + CameraOffset, NearClipPlane, FarClipPlane, Fog);

		v4 BackgroundColor = V4(0.15f, 0.15f, 0.15f, 0.0f);
		BeginDepthPeel(&Group, BackgroundColor);

		PushSimpleScene(&Group, &Scene);

		EndDepthPeel(&Group);
		EndRenderGroup(&Group);

		OpenGLRenderCommands(&RenderCommands, DrawRegion, DrawWidth, DrawHeight);


		// flushes and forces vsync
#if HANDMADE_USE_VSYNC
		[GlobalGLContext flushBuffer];
#else
		glFlush();
#endif

		u64 EndCounter = mach_absolute_time();
		f32 MeasuredSecondsPerFrame = OSXGetSecondsElapsed(LastCounter, EndCounter);
		LastCounter = EndCounter;

		tCameraShift += 0.1f * MeasuredSecondsPerFrame;

#if 0
		if (MinSPF > MeasuredSecondsPerFrame)
		{
			MinSPF = MeasuredSecondsPerFrame;
		}

		if (MaxSPF < MeasuredSecondsPerFrame)
		{
			MaxSPF = MeasuredSecondsPerFrame;
		}

		if (DisplayCounter++ == 300)
		{
			NSLog(@"Min: %.02fms  Max: %.02fms", 1000.0f * MinSPF, 1000.0f * MaxSPF);
			MinSPF = F32Max;
			MaxSPF = 0.0f;
			DisplayCounter = 0;
		}
#else
		frameTime += MeasuredSecondsPerFrame;
		++tickCounter;
		if (tickCounter == 60)
		{
			float avgFrameTime = frameTime / 60.0f;
			tickCounter = 0;
			frameTime = 0.0f;
			printf("frame time = %.02fms\n", 1000.0f * avgFrameTime);
		}
#endif
	}

	printf("Handmade Renderer Test finished running\n");

	} // @autoreleasepool
}

