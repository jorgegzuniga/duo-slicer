// C interface to the A1 slicing engine (used from Swift).
// All functions returning char* give a heap JSON string; free it with a1_free.
#ifndef A1ENGINE_H
#define A1ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct A1Engine A1Engine;
typedef void (*A1Progress)(double fraction, void* ctx);

A1Engine* a1_create(const char* profilesJson);
void a1_destroy(A1Engine* e);
void a1_free(void* p);

// Load a .3mf (or .3mf.zip). Returns {"ok":true,"project":{...}} or {"error":"..."}.
char* a1_open(A1Engine* e, const uint8_t* data, size_t len);
// Project description: plates, objects, filaments, presets, defaults.
char* a1_info(A1Engine* e);
// Effective values for the settings UI given options JSON
// {"process":..., "filaments":[...], "overrides":{...}, "colors":[...]}.
char* a1_settings(A1Engine* e, const char* optionsJson);

// Object placement (3MF row-vector matrix, 12 doubles). Returns 0 on success.
int a1_get_transform(A1Engine* e, int objectIndex, double* m12);
int a1_set_transform(A1Engine* e, int objectIndex, const double* m12);
// Rotate an object about its centre (axis 0=X,1=Y,2=Z, degrees) and drop it onto the bed.
int a1_rotate(A1Engine* e, int objectIndex, int axis, double degrees);
// Put the given world-space face normal of an object down on the bed.
int a1_lay_flat(A1Engine* e, int objectIndex, double nx, double ny, double nz);
// Place the largest flat face of an object on the bed.
int a1_auto_flat(A1Engine* e, int objectIndex);
int a1_reset_transform(A1Engine* e, int objectIndex);

// Triangles of a plate in printer coordinates: xyz (9 floats per triangle), fil (1 byte per triangle, 1-based filament),
// obj (int32 object index per triangle). Free each buffer with a1_free.
int a1_plate_mesh(A1Engine* e, int plate, float** xyz, uint8_t** fil, int32_t** obj, size_t* triCount);
// PNG thumbnail stored in the 3MF for a plate (may be absent -> returns -1).
int a1_plate_thumbnail(A1Engine* e, int plate, uint8_t** data, size_t* len);

// Slice one plate. Returns summary JSON: {"ok":true,"seconds":..,"grams":..,"layers":..,"filaments":[...],"warnings":[...]}.
char* a1_slice(A1Engine* e, int plate, const char* optionsJson, A1Progress progress, void* ctx);
// The last sliced plate as a Bambu .gcode.3mf archive.
int a1_sliced_file(A1Engine* e, uint8_t** data, size_t* len);
// The project re-saved with current orientations (normal .3mf).
int a1_export_project(A1Engine* e, uint8_t** data, size_t* len);
// Layer preview of the last slice: segments (x0,y0,x1,y1 floats) and per-segment meta (role in low 4 bits; filament in byte 2).
int a1_layer_count(A1Engine* e);
double a1_layer_z(A1Engine* e, int layer);
int a1_layer_preview(A1Engine* e, int layer, float** segs, uint16_t** meta, size_t* count);

#ifdef __cplusplus
}
#endif

#endif
