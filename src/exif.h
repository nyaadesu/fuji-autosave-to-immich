// Capture date from the EXIF of a JPEG or a Fujifilm RAF
#ifndef FUJI_EXIF_H
#define FUJI_EXIF_H

#define EXIF_DATE_LEN 11

/// @brief Read the local capture date ("YYYY-MM-DD") from EXIF DateTimeOriginal,
/// falling back to IFD0 DateTime. A RAF is read through its embedded JPEG.
/// The file comes from the camera, so every offset is bounds-checked.
/// @return 0 on success, -1 if the file has no usable EXIF date
int exif_capture_date(const char *path, char out[EXIF_DATE_LEN]);

#endif
