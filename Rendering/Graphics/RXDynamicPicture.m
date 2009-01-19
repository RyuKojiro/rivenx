//
//  RXDynamicPicture.m
//  rivenx
//
//  Created by Jean-Francois Roy on 14/12/2008.
//  Copyright 2008 MacStorm. All rights reserved.
//

#import <libkern/OSAtomic.h>

#import <OpenGL/CGLMacro.h>

#import "RXDynamicPicture.h"

static BOOL dynamic_picture_system_initialized = NO;

static int32_t dynamic_picture_vertex_bo_picture_capacity = 0;
static int32_t volatile active_dynamic_pictures = 0;
static GLuint* dynamic_picture_allocated_indices = NULL;

static GLuint dynamic_picture_vao = UINT32_MAX;
static GLuint dynamic_picture_vertex_bo = UINT32_MAX;

static OSSpinLock dynamic_picture_lock = OS_SPINLOCK_INIT;

static void initialize_dynamic_picture_system() {
	if (dynamic_picture_system_initialized)
		return;
	
	CGLContextObj cgl_ctx = [g_worldView loadContext];
	NSObject<RXOpenGLStateProtocol>* gl_state = g_loadContextState;
	
	dynamic_picture_vertex_bo_picture_capacity = 100;
	
	glGenBuffers(1, &dynamic_picture_vertex_bo);
	glGenVertexArraysAPPLE(1, &dynamic_picture_vao);
	
	[gl_state bindVertexArrayObject:dynamic_picture_vao];
	
	glBindBuffer(GL_ARRAY_BUFFER, dynamic_picture_vertex_bo); glReportError();
	if (GLEE_APPLE_flush_buffer_range)
		glBufferParameteriAPPLE(GL_ARRAY_BUFFER, GL_BUFFER_FLUSHING_UNMAP_APPLE, GL_FALSE);
	glBufferData(GL_ARRAY_BUFFER, dynamic_picture_vertex_bo_picture_capacity * 16 * sizeof(GLfloat), NULL, GL_STREAM_DRAW); glReportError();
	
	glEnableClientState(GL_VERTEX_ARRAY); glReportError();
	glVertexPointer(2, GL_FLOAT, 4 * sizeof(GLfloat), BUFFER_OFFSET(NULL, 0)); glReportError();
	
	glClientActiveTexture(GL_TEXTURE0);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY); glReportError();
	glTexCoordPointer(2, GL_FLOAT, 4 * sizeof(GLfloat), BUFFER_OFFSET(NULL, 2 * sizeof(GLfloat))); glReportError();
	
	[gl_state bindVertexArrayObject:0];
	
	// we created a new buffer object, so flush
	glFlush();
	
	active_dynamic_pictures = 0;
	dynamic_picture_allocated_indices = malloc(dynamic_picture_vertex_bo_picture_capacity * sizeof(GLuint));
	memset(dynamic_picture_allocated_indices, 0xFF, dynamic_picture_vertex_bo_picture_capacity * sizeof(GLuint));
	
	dynamic_picture_system_initialized = YES;
}

static void grow_dynamic_picture_vertex_bo() {
	CGLContextObj cgl_ctx = [g_worldView loadContext];
	NSObject<RXOpenGLStateProtocol>* gl_state = g_loadContextState;
	
	// bump capacity by 100
	GLuint old_capacity = dynamic_picture_vertex_bo_picture_capacity;
	dynamic_picture_vertex_bo_picture_capacity += 100;
	
	// resize the index allocation array
	dynamic_picture_allocated_indices = realloc(dynamic_picture_allocated_indices, dynamic_picture_vertex_bo_picture_capacity * sizeof(GLuint));
	memset(dynamic_picture_allocated_indices + old_capacity, 0xFF, 100 * sizeof(GLuint));
	
	GLuint alternate_bo;
	glGenBuffers(1, &alternate_bo);
	
	// bind the dynamic picture VAO and reconfigure it to use the alternate buffer object
	[gl_state bindVertexArrayObject:dynamic_picture_vao];
	
	// bind the vertex buffer in the alternate slot and re-allocate it to the new capacity
	glBindBuffer(GL_ARRAY_BUFFER, alternate_bo); glReportError();
	if (GLEE_APPLE_flush_buffer_range)
		glBufferParameteriAPPLE(GL_ARRAY_BUFFER, GL_BUFFER_FLUSHING_UNMAP_APPLE, GL_FALSE);
	glBufferData(GL_ARRAY_BUFFER, dynamic_picture_vertex_bo_picture_capacity * 16 * sizeof(GLfloat), NULL, GL_STREAM_DRAW); glReportError();
	
	glEnableClientState(GL_VERTEX_ARRAY); glReportError();
	glVertexPointer(2, GL_FLOAT, 4 * sizeof(GLfloat), BUFFER_OFFSET(NULL, 0)); glReportError();
	
	glClientActiveTexture(GL_TEXTURE0);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY); glReportError();
	glTexCoordPointer(2, GL_FLOAT, 4 * sizeof(GLfloat), BUFFER_OFFSET(NULL, 2 * sizeof(GLfloat))); glReportError();
	
	// reset the VAO state
	[gl_state bindVertexArrayObject:0];
	
	// map the alternate buffer object write-only
	GLfloat* destination = (GLfloat*)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY); glReportError();
	
	// bind the primary buffer object and map it read-only
	glBindBuffer(GL_ARRAY_BUFFER, dynamic_picture_vertex_bo); glReportError();
	GLfloat* source = (GLfloat*)glMapBuffer(GL_ARRAY_BUFFER, GL_READ_ONLY); glReportError();
	
	// copy the content of the primary buffer object into the alternate buffer object
	memcpy(destination, source, active_dynamic_pictures * 16 * sizeof(GLfloat));
	
	// unmap the primary buffer object
	glUnmapBuffer(GL_ARRAY_BUFFER); glReportError();
	
	// bind the alternate buffer object again, then flush and unmap it
	glBindBuffer(GL_ARRAY_BUFFER, alternate_bo); glReportError();
	if (GLEE_APPLE_flush_buffer_range)
		glFlushMappedBufferRangeAPPLE(GL_ARRAY_BUFFER, 0, active_dynamic_pictures * 16 * sizeof(GLfloat));
	glUnmapBuffer(GL_ARRAY_BUFFER); glReportError();
	
	// scrap the primary buffer object
	glDeleteBuffers(1, &dynamic_picture_vertex_bo);
	
	// we created a new buffer object, so flush
	glFlush();
	
	// the alternate buffer object is now the primary buffer object
	dynamic_picture_vertex_bo = alternate_bo;
}

static void insert_dynamic_picture_index(GLuint index, uint32_t position) {
	for (uint32_t i = active_dynamic_pictures - 1; i > position; i--)
		dynamic_picture_allocated_indices[i + 1] = dynamic_picture_allocated_indices[i];
	dynamic_picture_allocated_indices[position] = index;
}

static void remove_dynamic_picture_index(uint32_t position) {
	assert(active_dynamic_pictures > 0);
	
	for (uint32_t i = position; i < active_dynamic_pictures - 1; i++)
		dynamic_picture_allocated_indices[i] = dynamic_picture_allocated_indices[i + 1];
	dynamic_picture_allocated_indices[active_dynamic_pictures - 1] = 0xFFFFFFFF;
}

static GLuint allocate_dynamic_picture_index() {
	active_dynamic_pictures++;
	
	if (active_dynamic_pictures == dynamic_picture_vertex_bo_picture_capacity)
		grow_dynamic_picture_vertex_bo();
	
	GLuint index = 0;
	for (uint32_t i = 0; i < active_dynamic_pictures; i++, index++) {
		if (index < dynamic_picture_allocated_indices[i]) {
			insert_dynamic_picture_index(index, i);
			break;
		}
	}
	
	return index;
}

static void free_dynamic_picture_index(GLuint index) {
	for (uint32_t i = 0; i < active_dynamic_pictures; i++) {
		if (index == dynamic_picture_allocated_indices[i]) {
			remove_dynamic_picture_index(i);
			break;
		}
	}
	
	active_dynamic_pictures--;
}

@implementation RXDynamicPicture

+ (GLuint)sharedDynamicPictureUnpackBuffer {
	static GLuint dynamic_picture_unpack_buffer = 0;
	OSSpinLockLock(&dynamic_picture_lock);
	
	if (dynamic_picture_unpack_buffer) {
		OSSpinLockUnlock(&dynamic_picture_lock);
		return dynamic_picture_unpack_buffer;
	}
	
	CGLContextObj cgl_ctx = [g_worldView loadContext];
	CGLLockContext(cgl_ctx);
	
	// create a buffer object in which to decompress dynamic pictures, which at most can be the size of the card viewport
	glGenBuffers(1, &dynamic_picture_unpack_buffer); glReportError();
	glBindBuffer(GL_PIXEL_UNPACK_BUFFER, dynamic_picture_unpack_buffer); glReportError();
	if (GLEE_APPLE_flush_buffer_range)
		glBufferParameteriAPPLE(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_FLUSHING_UNMAP_APPLE, GL_FALSE);
	glBufferData(GL_PIXEL_UNPACK_BUFFER, kRXCardViewportSize.width * kRXCardViewportSize.height * 4, NULL, GL_STREAM_DRAW); glReportError();
	glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
	
	// we created a new buffer object, so flush
	glFlush();
	
	CGLUnlockContext(cgl_ctx);
	OSSpinLockUnlock(&dynamic_picture_lock);
	
	return dynamic_picture_unpack_buffer;
}

- (id)initWithTexture:(GLuint)texid samplingRect:(NSRect)samplingRect renderRect:(NSRect)renderRect owner:(id)owner {	
	// compute common vertex values
	float vertex_left_x = renderRect.origin.x;
	float vertex_right_x = vertex_left_x + renderRect.size.width;
	float vertex_bottom_y = renderRect.origin.y;
	float vertex_top_y = renderRect.origin.y + renderRect.size.height;
	
	CGLContextObj cgl_ctx = [g_worldView loadContext];
	CGLLockContext(cgl_ctx);
	
	if (!dynamic_picture_system_initialized)
		initialize_dynamic_picture_system();
	
	OSSpinLockLock(&dynamic_picture_lock);
	GLuint index = allocate_dynamic_picture_index();
	
	glBindBuffer(GL_ARRAY_BUFFER, dynamic_picture_vertex_bo); glReportError();
	GLfloat* vertex_attributes = (GLfloat*)BUFFER_OFFSET(glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY), index * 16 * sizeof(GLfloat)); glReportError();
	
	// 4 vertices per picture [<position.x position.y> <texcoord0.s texcoord0.t>], floats, triangle strip primitives
	// vertex 1
	vertex_attributes[0] = vertex_left_x;
	vertex_attributes[1] = vertex_bottom_y;
	
	vertex_attributes[2] = samplingRect.origin.x;
	vertex_attributes[3] = samplingRect.origin.y + samplingRect.size.height;
	
	// vertex 2
	vertex_attributes[4] = vertex_right_x;
	vertex_attributes[5] = vertex_bottom_y;
	
	vertex_attributes[6] = samplingRect.origin.x + samplingRect.size.width;
	vertex_attributes[7] = samplingRect.origin.y + samplingRect.size.height;
	
	// vertex 3
	vertex_attributes[8] = vertex_left_x;
	vertex_attributes[9] = vertex_top_y;
	
	vertex_attributes[10] = samplingRect.origin.x;
	vertex_attributes[11] = samplingRect.origin.y;
	
	// vertex 4
	vertex_attributes[12] = vertex_right_x;
	vertex_attributes[13] = vertex_top_y;
	
	vertex_attributes[14] = samplingRect.origin.x + samplingRect.size.width;
	vertex_attributes[15] = samplingRect.origin.y;
	
	if (GLEE_APPLE_flush_buffer_range)
		glFlushMappedBufferRangeAPPLE(GL_ARRAY_BUFFER, index * 16 * sizeof(GLfloat), 16);
	glUnmapBuffer(GL_ARRAY_BUFFER); glReportError();
	
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	
	OSSpinLockUnlock(&dynamic_picture_lock);
	CGLUnlockContext(cgl_ctx);
	
	self = [super initWithTexture:texid vao:dynamic_picture_vao index:index * 4 owner:owner];
	if (!self)
		return nil;
	
	return self;
}

- (void)dealloc {
	if (_index != UINT32_MAX) {
		OSSpinLockLock(&dynamic_picture_lock);
		free_dynamic_picture_index(_index / 4);
		OSSpinLockUnlock(&dynamic_picture_lock);
	}
	
	[super dealloc];
}

- (void)render:(const CVTimeStamp*)outputTime inContext:(CGLContextObj)cgl_ctx framebuffer:(GLuint)fbo {
	OSSpinLockLock(&dynamic_picture_lock);
	[super render:outputTime inContext:cgl_ctx framebuffer:fbo];
	OSSpinLockUnlock(&dynamic_picture_lock);
}

@end