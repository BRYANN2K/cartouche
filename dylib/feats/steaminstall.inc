#define NP_INSTALL_MAX 16384

static cJSON *read_install_file(const char *home, const char *name) {
    char path[1400], dir[1200];
    if (ensure_support_dir(home, dir, sizeof dir)) return NULL;
    np_support_path(path, sizeof path, home, name);
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return NULL;
    struct stat st;
    char buf[NP_INSTALL_MAX + 1];
    ssize_t n = -1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() &&
        st.st_size > 0 && st.st_size <= NP_INSTALL_MAX) n = read(fd, buf, (size_t)st.st_size);
    close(fd);
    return n > 0 && n == st.st_size ? cJSON_ParseWithLength(buf, (size_t)n) : NULL;
}

static int install_identity(const cJSON *j) {
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(j, "id");
    const cJSON *app = cJSON_GetObjectItemCaseSensitive(j, "appid");
    if (!cJSON_IsString(id) || strlen(id->valuestring) != 36 || !cJSON_IsNumber(app) ||
        app->valuedouble < 1 || app->valuedouble > 4294967295.0 || floor(app->valuedouble) != app->valuedouble) return 0;
    for (const char *p = id->valuestring; *p; p++)
        if (!((*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F') || (*p >= '0' && *p <= '9') || *p == '-')) return 0;
    return 1;
}

static int get_install_command(uintptr_t request, uintptr_t response) {
    (void)request;
    static int logged;
    if (!logged) { NP_LOG("install: command route called"); logged = 1; }
    const char *home = np_home_dir();
    cJSON *j = home ? read_install_file(home, "steam-install-command.json") : NULL;
    const cJSON *stamp = cJSON_GetObjectItemCaseSensitive(j, "created");
    const cJSON *op = cJSON_GetObjectItemCaseSensitive(j, "operation");
    const cJSON *sid = cJSON_GetObjectItemCaseSensitive(j, "steamid");
    char *account = home ? loginusers_steamid(home) : NULL;
    int valid = install_identity(j) && cJSON_IsNumber(stamp) &&
        fabs((double)time(NULL) - stamp->valuedouble) < 300 && cJSON_IsString(op) &&
        (!strcmp(op->valuestring,"install") || !strcmp(op->valuestring,"accept") || !strcmp(op->valuestring,"cancel")) &&
        cJSON_IsString(sid) && account && !strcmp(account,sid->valuestring);
    free(account);
    cJSON *prior = home ? read_install_file(home, "steam-install-status.json") : NULL;
    if (valid && install_identity(prior)) {
        const cJSON *a = cJSON_GetObjectItemCaseSensitive(j,"id"), *b = cJSON_GetObjectItemCaseSensitive(prior,"id");
        if (!strcmp(a->valuestring,b->valuestring)) cJSON_AddBoolToObject(j,"handled",1);
    }
    cJSON_Delete(prior);
    char *json = valid ? cJSON_PrintUnformatted(j) : NULL;
    size_t len = json ? strlen(json) : 2;
    uint8_t body[NP_INSTALL_MAX + 8], *p = body;
    *p++ = 10; pb_varint(&p, len);
    memcpy(p, json ? json : "{}", len); p += len;
    int ok = np_webui_parse_into(response, body, (uint32_t)(p-body));
    cJSON_free(json); cJSON_Delete(j);
    return ok ? RESULT_OK : RESULT_FAIL;
}

static int export_install_status(uintptr_t request, uintptr_t response) {
    size_t len = 0;
    const uint8_t *data = np_plausible_ptr(request) ? bytes_field(request + REQ_BYTES_OFF, &len) : NULL;
    if (!data || len < NP_TOKEN_LEN + 3 || len > NP_INSTALL_MAX ||
        memcmp(data, np_libexport_token(), NP_TOKEN_LEN) || data[NP_TOKEN_LEN] != '\n') return RESULT_FAIL;
    cJSON *j = cJSON_ParseWithLength((const char *)data + NP_TOKEN_LEN + 1, len - NP_TOKEN_LEN - 1);
    const cJSON *state = cJSON_GetObjectItemCaseSensitive(j,"state");
    const cJSON *fraction = cJSON_GetObjectItemCaseSensitive(j,"fraction");
    int valid = install_identity(j) && cJSON_IsString(state) && strlen(state->valuestring) <= 24 &&
        cJSON_IsNumber(fraction) && isfinite(fraction->valuedouble) && fraction->valuedouble >= 0 && fraction->valuedouble <= 1;
    const char *home = np_home_dir();
    char *json = valid ? cJSON_PrintUnformatted(j) : NULL;
    int ok = home && json && write_support_file(home,"steam-install-status.json",json,strlen(json)) == 0;
    cJSON_free(json); cJSON_Delete(j);
    const uint8_t reply[] = {8,1};
    if (ok) np_webui_parse_into(response,reply,sizeof reply);
    return ok ? RESULT_OK : RESULT_FAIL;
}
