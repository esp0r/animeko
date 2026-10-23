#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ani_session ani_session;
typedef struct ani_handle ani_handle;
typedef struct ani_info ani_info;
typedef struct ani_resume ani_resume;

typedef struct {
    const char *user_agent;
    const char *peer_fingerprint;
    const char *handshake_client_version;
    int download_rate_limit;
    int upload_rate_limit;
    int share_ratio_limit;
} ani_settings;

typedef struct {
    int64_t total, total_done, all_time_upload, all_time_download;
    int64_t download_payload_rate, upload_payload_rate;
    int64_t total_payload_download, total_payload_upload;
    float progress;
} ani_stats;

typedef struct {
    uint32_t handle_id;
    const char *peer_id;
    size_t peer_id_size;
    const char *client;
    const char *ip_addr;
    uint16_t ip_port;
    float progress;
    int64_t total_download, total_upload;
    uint32_t flags;
} ani_peer;

enum ani_event_kind {
    ANI_CHECKED = 1, ANI_METADATA, ANI_PIECE_DOWNLOADING, ANI_PIECE_FINISHED,
    ANI_FINISHED, ANI_STATS, ANI_FILE_COMPLETED, ANI_REMOVED, ANI_RESUME
};

/* Payloads and strings are borrowed and valid only during the callback.
 * Event callbacks run synchronously inside ani_session_poll.
 * Peer filtering runs on libtorrent's network thread. */
typedef void (*ani_event_callback)(void *, int, uint32_t, int, const void *);
typedef int (*ani_peer_filter)(void *, const ani_peer *);
typedef void (*ani_peer_callback)(void *, const ani_peer *);

/* Failures return null/-1 and set a thread-local diagnostic. No C++ exception
 * may cross this ABI. Owners must serialize close against all their calls. */
const char *ani_last_error(void);
ani_session *ani_session_create(const ani_settings *, ani_peer_filter, void *);
int ani_session_destroy(ani_session *);
int ani_session_configure(ani_session *, const ani_settings *);
int ani_session_resume(ani_session *);
int ani_session_poll(ani_session *, ani_event_callback, void *);
ani_handle *ani_session_add(ani_session *, const char *magnet, const char *torrent_path,
                            const char *resume_path, const char *save_path);
int ani_session_remove(ani_session *, ani_handle *);
int ani_handle_destroy(ani_handle *);
uint32_t ani_handle_id(const ani_handle *);
int ani_handle_valid(const ani_handle *);
int ani_handle_state(const ani_handle *);
int ani_handle_resume(ani_handle *);
int ani_handle_post_status(ani_handle *);
int ani_handle_post_resume(ani_handle *);
int ani_handle_priority(ani_handle *, int index, int priority);
int ani_handle_deadline(ani_handle *, int index, int deadline);
int ani_handle_clear_deadlines(ani_handle *);
int ani_handle_tracker(ani_handle *, const char *, int tier, int fail_limit);
const char *ani_handle_magnet(ani_handle *);
int ani_handle_peers(ani_handle *, ani_peer_callback, void *);
ani_info *ani_handle_info(ani_handle *);
void ani_info_destroy(ani_info *);
const char *ani_info_name(const ani_info *);
int ani_info_file_count(const ani_info *);
int ani_info_piece_count(const ani_info *);
int64_t ani_info_piece_length(const ani_info *);
int64_t ani_info_last_piece_size(const ani_info *);
const char *ani_info_file_name(const ani_info *, int);
const char *ani_info_file_path(const ani_info *, int);
int64_t ani_info_file_size(const ani_info *, int);
/* Resume payload can be retained beyond an event by making an owned copy. */
ani_resume *ani_resume_copy(const void *);
int ani_resume_save(const ani_resume *, const char *);
void ani_resume_destroy(ani_resume *);

#ifdef __cplusplus
}
#endif
