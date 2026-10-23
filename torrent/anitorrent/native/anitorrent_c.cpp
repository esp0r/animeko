#include "anitorrent_c.h"
#include "session_t.hpp"
#include <exception>
#include <stdexcept>
#include <string>

namespace {
thread_local std::string last_error;
template<typename F, typename T> T guarded(F f, T fallback) noexcept {
    try { last_error.clear(); return f(); }
    catch (const std::exception &e) { last_error = e.what(); }
    catch (...) { last_error = "Unknown native torrent failure"; }
    return fallback;
}
template<typename F> int checked(F f) noexcept {
    return guarded([&] { f(); return 0; }, -1);
}
anilt::session_settings_t settings(const ani_settings &s) {
    anilt::session_settings_t result;
    result.user_agent = s.user_agent;
    result.peer_fingerprint = s.peer_fingerprint;
    result.handshake_client_version = s.handshake_client_version;
    result.download_rate_limit = s.download_rate_limit;
    result.upload_rate_limit = s.upload_rate_limit;
    result.share_ratio_limit = s.share_ratio_limit;
    result.connections_limit = 200;
    for (auto node : {"router.utorrent.com:6881", "router.bittorrent.com:6881",
                      "dht.transmissionbt.com:6881", "router.bitcomet.com:6881"})
        result.dht_bootstrap_nodes_extra_add(node);
    return result;
}
ani_peer peer(const anilt::peer_info_t &p) {
    return {p.torrent_handle_id, p.peer_id.data(), p.peer_id.size(), p.client.c_str(),
            p.ip_addr.c_str(), p.ip_port, p.progress, p.total_download, p.total_upload, p.flags};
}
struct listener final : anilt::event_listener_t {
    ani_event_callback callback;
    void *context;
    listener(ani_event_callback cb, void *ctx) : callback(cb), context(ctx) {}
    void emit(int type, uint32_t id, int index = 0, const void *data = nullptr) {
        callback(context, type, id, index, data);
    }
    void on_checked(anilt::handle_id_t id) override { emit(ANI_CHECKED, id); }
    void on_metadata_received(anilt::handle_id_t id) override { emit(ANI_METADATA, id); }
    void on_block_downloading(anilt::handle_id_t id, int32_t p, int) override { emit(ANI_PIECE_DOWNLOADING, id, p); }
    void on_piece_finished(anilt::handle_id_t id, int32_t p) override { emit(ANI_PIECE_FINISHED, id, p); }
    void on_torrent_state_changed(anilt::handle_id_t id, anilt::torrent_state_t s) override {
        if (s == anilt::finished || s == anilt::seeding) emit(ANI_FINISHED, id);
    }
    void on_status_update(anilt::handle_id_t id, anilt::torrent_stats_t &s) override {
        ani_stats copy{s.total, s.total_done, s.all_time_upload, s.all_time_download,
                       s.download_payload_rate, s.upload_payload_rate,
                       s.total_payload_download, s.total_payload_upload, s.progress};
        emit(ANI_STATS, id, 0, &copy);
    }
    void on_file_completed(anilt::handle_id_t id, int index) override { emit(ANI_FILE_COMPLETED, id, index); }
    void on_torrent_removed(anilt::handle_id_t id, const char *name) override { emit(ANI_REMOVED, id, 0, name); }
    void on_save_resume_data(anilt::handle_id_t id, anilt::torrent_resume_data_t &data) override {
        emit(ANI_RESUME, id, 0, &data);
    }
};
}

struct ani_session {
    struct filter final : anilt::peer_filter_t {
        ani_peer_filter callback;
        void *context;
        bool on_filter(const anilt::peer_info_t &p) override {
            auto copy = peer(p);
            return callback && callback(context, &copy) != 0;
        }
    } peer_filter;
    // Destroy the session before the filter, so libtorrent cannot call freed data.
    anilt::session_t native;
};
struct ani_handle { anilt::torrent_handle_t native; std::string magnet; };
struct ani_info { anilt::torrent_info_t native; };
struct ani_resume { anilt::torrent_resume_data_t native; };

extern "C" {
const char *ani_last_error(void) { return last_error.c_str(); }
ani_session *ani_session_create(const ani_settings *s, ani_peer_filter cb, void *ctx) {
    return guarded([&] {
        auto result = std::make_unique<ani_session>();
        result->peer_filter.callback = cb;
        result->peer_filter.context = ctx;
        result->native.start(settings(*s));
        result->native.set_peer_filter(&result->peer_filter);
        return result.release();
    }, static_cast<ani_session *>(nullptr));
}
int ani_session_destroy(ani_session *s) { return checked([&] { delete s; }); }
int ani_session_configure(ani_session *s, const ani_settings *c) { return checked([&] { s->native.apply_settings(settings(*c)); }); }
int ani_session_resume(ani_session *s) { return checked([&] { s->native.resume(); }); }
int ani_session_poll(ani_session *s, ani_event_callback cb, void *ctx) {
    return checked([&] { listener l(cb, ctx); s->native.process_events(&l); });
}
ani_handle *ani_session_add(ani_session *s, const char *magnet, const char *torrent,
                            const char *resume, const char *save) {
    return guarded([&] {
        anilt::torrent_add_info_t info;
        if (magnet && *magnet) {
            info.kind = anilt::torrent_add_info_t::kKindMagnetUri;
            info.magnet_uri = magnet;
        } else {
            info.kind = anilt::torrent_add_info_t::kKindTorrentFile;
            info.torrent_file_path = torrent ? torrent : "";
        }
        if (resume) info.resume_data_path = resume;
        auto h = std::make_unique<ani_handle>();
        if (!s->native.start_download(h->native, info, save))
            throw std::runtime_error("libtorrent rejected torrent");
        return h.release();
    }, static_cast<ani_handle *>(nullptr));
}
int ani_session_remove(ani_session *s, ani_handle *h) { return checked([&] { s->native.release_handle(h->native); }); }
int ani_handle_destroy(ani_handle *h) { return checked([&] { delete h; }); }
uint32_t ani_handle_id(const ani_handle *h) { return h->native.id; }
int ani_handle_valid(const ani_handle *h) { return guarded([&] { return h->native.is_valid() ? 1 : 0; }, -1); }
int ani_handle_state(const ani_handle *h) { return guarded([&] { return h->native.get_state(); }, -1); }
int ani_handle_resume(ani_handle *h) { return checked([&] { h->native.resume(); }); }
int ani_handle_post_status(ani_handle *h) { return checked([&] { h->native.post_status_updates(); }); }
int ani_handle_post_resume(ani_handle *h) { return checked([&] { h->native.post_save_resume(); }); }
int ani_handle_priority(ani_handle *h, int i, int p) { return checked([&] { h->native.set_file_priority(i, p); }); }
int ani_handle_deadline(ani_handle *h, int i, int d) { return checked([&] { h->native.set_piece_deadline(i, d); }); }
int ani_handle_clear_deadlines(ani_handle *h) { return checked([&] { h->native.clear_piece_deadlines(); }); }
int ani_handle_tracker(ani_handle *h, const char *t, int tier, int limit) { return checked([&] { h->native.add_tracker(t, tier, limit); }); }
const char *ani_handle_magnet(ani_handle *h) {
    return guarded([&] { h->magnet = h->native.make_magnet_uri(); return h->magnet.c_str(); }, static_cast<const char *>(nullptr));
}
int ani_handle_peers(ani_handle *h, ani_peer_callback cb, void *ctx) {
    return checked([&] {
        std::vector<anilt::peer_info_t> peers;
        h->native.get_peers(peers);
        for (const auto &p : peers) { auto copy = peer(p); cb(ctx, &copy); }
    });
}
ani_info *ani_handle_info(ani_handle *h) {
    return guarded([&] {
        if (h->native.reload_file() != anilt::torrent_handle_t::kReloadFileSuccess)
            throw std::runtime_error("Torrent metadata unavailable");
        return new ani_info{*h->native.get_info_view()};
    }, static_cast<ani_info *>(nullptr));
}
void ani_info_destroy(ani_info *i) { delete i; }
const char *ani_info_name(const ani_info *i) { return i->native.name.c_str(); }
int ani_info_file_count(const ani_info *i) { return static_cast<int>(i->native.files.size()); }
int ani_info_piece_count(const ani_info *i) { return i->native.num_pieces; }
int64_t ani_info_piece_length(const ani_info *i) { return i->native.piece_length; }
int64_t ani_info_last_piece_size(const ani_info *i) { return i->native.last_piece_size; }
const char *ani_info_file_name(const ani_info *i, int n) {
    return guarded([&] { return i->native.files.at(n).name.c_str(); }, static_cast<const char *>(nullptr));
}
const char *ani_info_file_path(const ani_info *i, int n) {
    return guarded([&] { return i->native.files.at(n).path.c_str(); }, static_cast<const char *>(nullptr));
}
int64_t ani_info_file_size(const ani_info *i, int n) {
    return guarded([&] { return static_cast<int64_t>(i->native.files.at(n).size); }, int64_t(-1));
}
ani_resume *ani_resume_copy(const void *p) {
    return guarded([&] { return new ani_resume{*static_cast<const anilt::torrent_resume_data_t *>(p)}; }, static_cast<ani_resume *>(nullptr));
}
int ani_resume_save(const ani_resume *r, const char *p) { return checked([&] { r->native.save_to_file(p); }); }
void ani_resume_destroy(ani_resume *r) { delete r; }
}
