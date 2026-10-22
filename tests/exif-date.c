// Print the EXIF capture date the receiver would file each argument under
#include <stdio.h>
#include "exif.h"

int main(int argc, char **argv) {
	int rc = 0;
	for (int i = 1; i < argc; i++) {
		char date[EXIF_DATE_LEN];
		if (exif_capture_date(argv[i], date) == 0) {
			printf("%s\n", date);
		} else {
			printf("none\n");
			rc = 1;
		}
	}
	return rc;
}
