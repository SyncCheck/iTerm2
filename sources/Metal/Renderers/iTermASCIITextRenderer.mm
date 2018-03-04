//
//  iTermASCIITextRenderer.m
//  iTerm2Shared
//
//  Created by George Nachman on 2/17/18.
//

#import "iTermASCIITextRenderer.h"

#import "iTermASCIITexture.h"
#import "iTermData.h"
#import "iTermMetalGlyphKey.h"
#import "iTermTextRenderer.h"
#import "NSDictionary+iTerm.h"
#import "NSMutableData+iTerm.h"
#import "ScreenChar.h"

@implementation iTermASCIIRow
@end

@interface iTermASCIITextRendererTransientState()
@property (nonatomic, strong) iTermASCIITextureGroup *asciiTextureGroup;
@property (nonatomic, strong) iTermMetalBufferPool *configPool;
@property (nonatomic, strong) NSNumber *iteration;
@property (nonatomic, readonly) NSMutableArray<iTermPooledTexture *> *pooledTextures;
@property (nonatomic, strong) iTermTexturePool *texturePool;
@end

@implementation iTermASCIITextRendererTransientState {
    iTermPreciseTimerStats _stats[iTermASCIITextRendererStatCount];
    NSMutableArray<iTermPooledTexture *> *_pooledTextures;
}

- (NSMutableArray<iTermPooledTexture *> *)pooledTextures {
    if (!_pooledTextures) {
        _pooledTextures = [NSMutableArray array];
    }
    return _pooledTextures;
}

- (NSString *)formatScreenChar:(screen_char_t)c {
    return [NSString stringWithFormat:@"[code=%@ fgMode=%@ foreground=%@ fgGreen=%@ fgBlue=%@ bgMode=%@ background=%@ bgGreen=%@ bgBlue=%@ complex=%@ bold=%@ faint=%@ italic=%@ blink=%@ underline=%@ image=%@ unused=%@ urlcode=%@]",
            @(c.code),
            @(c.foregroundColorMode),
            @(c.foregroundColor),
            @(c.fgGreen),
            @(c.fgBlue),
            @(c.backgroundColorMode),
            @(c.backgroundColor),
            @(c.bgGreen),
            @(c.bgBlue),
            @(c.complexChar),
            @(c.bold),
            @(c.faint),
            @(c.italic),
            @(c.blink),
            @(c.underline),
            @(c.image),
            @(c.unused),
            @(c.urlCode)];
}

- (NSString *)formatColor:(iTermCellColors *)color {
    return [NSString stringWithFormat:@"[nonascii=%@ textColor=%@ backgroundColor=%@ underlineColor=%@ underlineStyle=%@ useThinStrokes=%@]",
            @(color->nonascii),
            iTermStringFromColorVectorFloat4(color->textColor),
            iTermStringFromColorVectorFloat4(color->backgroundColor),
            iTermStringFromColorVectorFloat4(color->underlineColor),
            @(color->underlineStyle),
            @(color->useThinStrokes)];
}

- (void)writeDebugInfoToFolder:(NSURL *)folder {
    [super writeDebugInfoToFolder:folder];
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        screen_char_t *allLines = reinterpret_cast<screen_char_t *>(self.lines.mutableBytes);
        for (int i = 0; i < self.cellConfiguration.gridSize.height; i++) {
            // Write out screen chars
            int width = self.cellConfiguration.gridSize.width + 1;
            const screen_char_t *line = &allLines[width * i];
            for (int j = 0; j + 1 < width; j++) {
                [s appendFormat:@"(%4d, %4d): %@\n", j, i, [self formatScreenChar:line[j]]];
            }
            [s appendString:@"\n"];
        }
        [s writeToURL:[folder URLByAppendingPathComponent:@"screen_char_t.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }

    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        iTermCellColors *colors = reinterpret_cast<iTermCellColors *>(self.colorsBuffer.contents);
        for (int i = 0; i < self.cellConfiguration.gridSize.height; i++) {
            // Write out screen chars
            int width = self.cellConfiguration.gridSize.width + 1;
            for (int j = 0; j + 1 < width; j++) {
                [s appendFormat:@"(%4d, %4d): %@\n", j, i, [self formatColor:&colors[i * width + j]]];
            }
            [s appendString:@"\n"];
        }
        [s writeToURL:[folder URLByAppendingPathComponent:@"colors.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }

    NSString *s = [NSString stringWithFormat:@"backgroundTexture=%@\nasciiUnderlineDescriptor=%@\n",
                   _backgroundTexture,
                   iTermMetalUnderlineDescriptorDescription(&_underlineDescriptor)];
    [s writeToURL:[folder URLByAppendingPathComponent:@"state.txt"]
       atomically:NO
         encoding:NSUTF8StringEncoding
            error:NULL];
}

- (iTermPreciseTimerStats *)stats {
    return _stats;
}

- (int)numberOfStats {
    return iTermASCIITextRendererStatCount;
}

- (NSString *)nameForStat:(int)i {
    static NSArray *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[ @"ascii.newDims",
                   @"ascii.newQuad",
                   @"ascii.newConfig",
                   @"ascii.blit" ];
    });
    return names[i];
}

@end

@implementation iTermASCIITextRenderer {
    iTermMetalCellRenderer *_cellRenderer;
    iTermMetalMixedSizeBufferPool *_screenCharPool;
    iTermASCIITextureGroup *_asciiTextureGroup;
    iTermMetalBufferPool *_dimensionsPool;
    iTermMetalBufferPool *_configPool;
    iTermMetalBufferPool *_quadPool;
    id<MTLBuffer> _models;
    id<MTLBuffer> _evensBuffer;
    id<MTLBuffer> _oddsBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        // This is here because I need a c++ place to stick it.
        static_assert(sizeof(screen_char_t) == SIZEOF_SCREEN_CHAR_T, "Screen char sizes unequal");

        _cellRenderer = [[iTermMetalCellRenderer alloc] initWithDevice:device
                                                    vertexFunctionName:@"iTermASCIITextVertexShader"
                                                  fragmentFunctionName:@"iTermASCIITextFragmentShader"
                                                              blending:[iTermMetalBlending compositeSourceOver]
                                                        piuElementSize:sizeof(screen_char_t)
                                                   transientStateClass:[iTermASCIITextRendererTransientState class]];
        _screenCharPool = [[iTermMetalMixedSizeBufferPool alloc] initWithDevice:device
                                                                       capacity:iTermMetalDriverMaximumNumberOfFramesInFlight + 1
                                                                           name:@"ASCII screen_char_t"];
        _dimensionsPool = [[iTermMetalBufferPool alloc] initWithDevice:device
                                                                  name:@"Dimensions"
                                                            bufferSize:sizeof(iTermTextureDimensions)];
        _configPool = [[iTermMetalBufferPool alloc] initWithDevice:device
                                                              name:@"Config"
                                                        bufferSize:sizeof(iTermASCIITextConfiguration)];
        _quadPool =  [[iTermMetalBufferPool alloc] initWithDevice:device
                                                             name:@"Quad"
                                                       bufferSize:sizeof(iTermVertex) * 6];

        // Use a generic color model for blending. No need to use a buffer pool here because this is only
        // created once.
        NSData *subpixelModelData = [iTermTextRenderer subpixelModelData];
        _models = [_cellRenderer.device newBufferWithBytes:subpixelModelData.bytes
                                                    length:subpixelModelData.length
                                                   options:MTLResourceStorageModeManaged];

        int oddsValue = 1;
        int evensValue = 0;
        _evensBuffer = [_cellRenderer.device newBufferWithBytes:&evensValue length:sizeof(evensValue) options:MTLResourceStorageModeShared];
        _oddsBuffer = [_cellRenderer.device newBufferWithBytes:&oddsValue length:sizeof(oddsValue) options:MTLResourceStorageModeShared];
        _models.label = @"Subpixel models";
    }
    return self;
}

- (BOOL)rendererDisabled {
    return NO;
}

- (iTermMetalFrameDataStat)createTransientStateStat {
    return iTermMetalFrameDataStatPqCreateASCIITextTS;
}

- (__kindof iTermMetalRendererTransientState * _Nonnull)createTransientStateForCellConfiguration:(iTermCellRenderConfiguration *)configuration
                                                                                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    __kindof iTermMetalCellRendererTransientState * _Nonnull transientState =
    [_cellRenderer createTransientStateForCellConfiguration:configuration
                                              commandBuffer:commandBuffer];
    [self initializeTransientState:transientState];
    return transientState;
}

- (void)initializeTransientState:(iTermASCIITextRendererTransientState *)tState {
    tState.asciiTextureGroup = _asciiTextureGroup;
}

- (void)createPipelineState:(iTermASCIITextRendererTransientState *)tState {
    tState.iteration = @(tState.iteration.intValue + 1);
    tState.pipelineState = [_cellRenderer pipelineStateForKey:[tState.iteration stringValue]];
}

- (id<MTLBuffer>)extraWideQuadWithCellSize:(CGSize)cellSize
                               textureSize:(vector_float2)textureSize
                               poolContext:(iTermMetalBufferPoolContext *)poolContext {
    const float vw = static_cast<float>(cellSize.width * 3);
    const float vh = static_cast<float>(cellSize.height);

    const float w = vw / textureSize.x;
    const float h = vh / textureSize.y;

    const iTermVertex vertices[] = {
        // Pixel Positions, Texture Coordinates
        { { vw,  0 },       { w, 0 } },
        { { 0,   0 },       { 0, 0 } },
        { { 0,  vh },       { 0, h } },

        { { vw,  0 },       { w, 0 } },
        { { 0,  vh },       { 0, h } },
        { { vw, vh },       { w, h } },
    };
    id<MTLBuffer> quad = [_quadPool requestBufferFromContext:poolContext
                                                   withBytes:vertices
                                              checkIfChanged:YES];
    quad.label = @"ASCII Quad";
    return quad;
}

- (id<MTLBuffer>)newConfigBufferForState:(iTermASCIITextRendererTransientState *)tState {
    __block id<MTLBuffer> configBuffer;
    [tState measureTimeForStat:iTermASCIITextRendererStatNewConfig ofBlock:^{
        iTermASCIITextConfiguration config = {
            .gridSize = simd_make_uint2(tState.cellConfiguration.gridSize.width,
                                        tState.cellConfiguration.gridSize.height),
            .cellSize = simd_make_float2(tState.cellConfiguration.cellSize.width,
                                         tState.cellConfiguration.cellSize.height),
            .scale = static_cast<float>(tState.cellConfiguration.scale),
            .atlasSize = tState.asciiTextureGroup.atlasSize
        };
        configBuffer = [_configPool requestBufferFromContext:tState.poolContext
                                                   withBytes:&config
                                              checkIfChanged:YES];
        configBuffer.label = @"ASCII config";
    }];
    return configBuffer;
}

- (id<MTLBuffer>)newVertexBufferForState:(iTermASCIITextRendererTransientState *)tState
                             textureSize:(vector_float2)textureSize {
    __block id<MTLBuffer> vertexBuffer;
    [tState measureTimeForStat:iTermASCIITextRendererStatNewQuad ofBlock:^{
        vertexBuffer = [self extraWideQuadWithCellSize:tState.cellConfiguration.cellSize
                                           textureSize:textureSize
                                           poolContext:tState.poolContext];
        vertexBuffer.label = @"ASCII Vertexes";
    }];
    return vertexBuffer;
}

- (id<MTLBuffer>)newTextureDimensionsBufferForState:(iTermASCIITextRendererTransientState *)tState
                                  textureDimensions:(iTermTextureDimensions *)textureDimensions {
    __block id<MTLBuffer> textureDimensionsBuffer;
    [tState measureTimeForStat:iTermASCIITextRendererStatNewDims ofBlock:^{
        textureDimensionsBuffer = [_dimensionsPool requestBufferFromContext:tState.poolContext
                                                                  withBytes:textureDimensions
                                                             checkIfChanged:YES];
        textureDimensionsBuffer.label = @"ASCII dimensions";
    }];
    return textureDimensionsBuffer;
}

- (iTermTextureDimensions)textureDimensionsForState:(iTermASCIITextRendererTransientState *)tState {
    iTermTextureDimensions textureDimensions = {
        .textureSize = tState.asciiTextureGroup.atlasSize,
        .cellSize = simd_make_float2(tState.cellConfiguration.cellSize.width, tState.cellConfiguration.cellSize.height),
        .underlineOffset = static_cast<float>(tState.cellConfiguration.cellSize.height - tState.underlineDescriptor.offset * tState.cellConfiguration.scale),
        .underlineThickness = static_cast<float>(tState.underlineDescriptor.thickness * tState.cellConfiguration.scale),
        .scale = static_cast<float>(tState.cellConfiguration.scale)
    };
    return textureDimensions;
}
- (NSDictionary<NSNumber *, id<MTLTexture>> *)newTexturesForState:(iTermASCIITextRendererTransientState *)tState {
    static const iTermASCIITextureAttributes B = iTermASCIITextureAttributesBold;
    static const iTermASCIITextureAttributes I = iTermASCIITextureAttributesItalic;
    static const iTermASCIITextureAttributes T = iTermASCIITextureAttributesThinStrokes;
    NSDictionary<NSNumber *, id<MTLTexture>> *textures =
    @{
      @(iTermTextureIndexPlain):          [tState.asciiTextureGroup asciiTextureForAttributes:0].textureArray.texture,
      @(iTermTextureIndexBold):           [tState.asciiTextureGroup asciiTextureForAttributes:B].textureArray.texture,
      @(iTermTextureIndexItalic):         [tState.asciiTextureGroup asciiTextureForAttributes:I].textureArray.texture,
      @(iTermTextureIndexBoldItalic):     [tState.asciiTextureGroup asciiTextureForAttributes:B | I].textureArray.texture,
      @(iTermTextureIndexThin):           [tState.asciiTextureGroup asciiTextureForAttributes:T].textureArray.texture,
      @(iTermTextureIndexThinBold):       [tState.asciiTextureGroup asciiTextureForAttributes:B | T].textureArray.texture,
      @(iTermTextureIndexThinItalic):     [tState.asciiTextureGroup asciiTextureForAttributes:I | T].textureArray.texture,
      @(iTermTextureIndexThinBoldItalic): [tState.asciiTextureGroup asciiTextureForAttributes:B | I | T].textureArray.texture,
      @(iTermTextureIndexBackground):     tState.tempTexture,
      };
    return textures;
}

- (id<MTLRenderCommandEncoder>)newRenderEncoderAfterBlittingToTempTextureWithState:(iTermASCIITextRendererTransientState *)tState {
    __block id<MTLRenderCommandEncoder> renderEncoder;
    [tState measureTimeForStat:iTermASCIITextRendererStatBlit ofBlock:^{
        renderEncoder = tState.blitBlock(tState.backgroundTexture, tState.tempTexture);
        [self createPipelineState:tState];
    }];
    return renderEncoder;
}

- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)originalRenderEncoder
               transientState:(__kindof iTermMetalCellRendererTransientState *)transientState {
    iTermASCIITextRendererTransientState *tState = transientState;

    id<MTLRenderCommandEncoder> renderEncoder = [self newRenderEncoderAfterBlittingToTempTextureWithState:tState];
    NSDictionary<NSNumber *, id<MTLTexture>> *textures = [self newTexturesForState:tState];

    id<MTLBuffer> textureDimensionsBuffer;
    iTermTextureDimensions textureDimensions = [self textureDimensionsForState:tState];

    textureDimensionsBuffer = [self newTextureDimensionsBufferForState:tState
                                                     textureDimensions:&textureDimensions];

    tState.vertexBuffer = [self newVertexBufferForState:tState textureSize:textureDimensions.textureSize];
    id<MTLBuffer> configBuffer = [self newConfigBufferForState:tState];
    id<MTLBuffer> screenChars = [_screenCharPool requestBufferFromContext:tState.poolContext
                                                                     size:tState.lines.length
                                                                    bytes:tState.lines.mutableBytes];

    [self drawPassEven:YES tState:tState config:configBuffer textureDimensions:textureDimensionsBuffer renderEncoder:renderEncoder textures:textures screenChars:screenChars];
    renderEncoder = [self newRenderEncoderAfterBlittingToTempTextureWithState:tState];
    [self drawPassEven:NO tState:tState config:configBuffer textureDimensions:textureDimensionsBuffer renderEncoder:renderEncoder textures:textures screenChars:screenChars];
}

- (void)drawPassEven:(BOOL)even
              tState:(iTermASCIITextRendererTransientState *)tState
              config:(id<MTLBuffer>)configBuffer
   textureDimensions:(id<MTLBuffer>)textureDimensionsBuffer
       renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
            textures:(NSDictionary<NSNumber *, id<MTLTexture>> *)textures
         screenChars:(id<MTLBuffer>)screenChars {
    NSDictionary<NSNumber *, id<MTLBuffer>> *vertexBuffers = @{
          @(iTermVertexInputIndexVertices): tState.vertexBuffer,
          @(iTermVertexInputIndexPerInstanceUniforms): screenChars,
          @(iTermVertexInputIndexOffset): tState.offsetBuffer,
          @(iTermVertexInputCellColors): tState.colorsBuffer,
          @(iTermVertexInputIndexASCIITextConfiguration): configBuffer };

    [_cellRenderer drawWithTransientState:tState
                            renderEncoder:renderEncoder
                         numberOfVertices:6
                             numberOfPIUs:screenChars.length / sizeof(screen_char_t)
                            vertexBuffers:[vertexBuffers dictionaryBySettingObject:even ? _evensBuffer : _oddsBuffer forKey:@(iTermVertexInputMask)]
                          fragmentBuffers:@{ @(iTermFragmentBufferIndexColorModels): _models,
                                             @(iTermFragmentInputIndexTextureDimensions): textureDimensionsBuffer }
                                 textures:textures];
}

- (void)setASCIICellSize:(CGSize)cellSize
      creationIdentifier:(id)creationIdentifier
                creation:(NSDictionary<NSNumber *, iTermCharacterBitmap *> *(^)(char, iTermASCIITextureAttributes))creation {
    iTermASCIITextureGroup *replacement = [[iTermASCIITextureGroup alloc] initWithCellSize:cellSize
                                                                                    device:_cellRenderer.device
                                                                        creationIdentifier:(id)creationIdentifier
                                                                                  creation:creation];
    if (![replacement isEqual:_asciiTextureGroup]) {
        _asciiTextureGroup = replacement;
    }
}


@end
