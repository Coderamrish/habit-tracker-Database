-- EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       
CREATE EXTENSION IF NOT EXISTS "pg_trgm";         
CREATE EXTENSION IF NOT EXISTS "btree_gin";       
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; 
-- ENUMS
CREATE TYPE habit_frequency       AS ENUM ('daily', 'weekly', 'monthly', 'custom');
CREATE TYPE habit_goal_type       AS ENUM ('boolean', 'count', 'duration');  
CREATE TYPE subscription_plan     AS ENUM ('free', 'pro', 'team');
CREATE TYPE subscription_status   AS ENUM ('active', 'cancelled', 'expired', 'trial');
CREATE TYPE notification_type     AS ENUM ('habit_reminder', 'streak_alert', 'achievement', 'friend_invite', 'group_update', 'system');
CREATE TYPE notification_status   AS ENUM ('pending', 'sent', 'delivered', 'failed', 'dismissed');
CREATE TYPE friendship_status     AS ENUM ('pending', 'accepted', 'blocked');
CREATE TYPE group_role            AS ENUM ('owner', 'admin', 'member');
CREATE TYPE achievement_type      AS ENUM ('streak', 'completion', 'social', 'special');
CREATE TYPE points_tx_type        AS ENUM ('earned', 'spent', 'bonus', 'penalty', 'refund');
CREATE TYPE share_platform        AS ENUM ('instagram', 'twitter', 'facebook', 'whatsapp', 'link', 'other');
CREATE TYPE analytics_period      AS ENUM ('daily', 'weekly', 'monthly');

-- USERS
CREATE TABLE users (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    username            VARCHAR(50) NOT NULL UNIQUE,
    email               VARCHAR(255) NOT NULL UNIQUE,
    password_hash       TEXT        NOT NULL,
    display_name        VARCHAR(100),
    avatar_url          TEXT,
    bio                 TEXT,
    timezone            VARCHAR(60) DEFAULT 'UTC',
    locale              VARCHAR(10) DEFAULT 'en',

    -- security
    email_verified      BOOLEAN     DEFAULT FALSE,
    email_verified_at   TIMESTAMPTZ,
    two_fa_enabled      BOOLEAN     DEFAULT FALSE,
    two_fa_secret       TEXT,                       
    failed_login_count  SMALLINT    DEFAULT 0,
    locked_until        TIMESTAMPTZ,              
    last_login_at       TIMESTAMPTZ,
    last_login_ip       INET,

    -- Soft delete
    deleted_at          TIMESTAMPTZ,               
    deleted_by          UUID,                    

    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_email        ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_username     ON users(username) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_username_trgm ON users USING gin(username gin_trgm_ops);  

-- USER SESSIONS (jwt token tracking)

CREATE TABLE user_sessions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    refresh_token   TEXT        NOT NULL UNIQUE,
    device_info     JSONB,                        
    ip_address      INET,
    is_revoked      BOOLEAN     DEFAULT FALSE,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_sessions_user_id      ON user_sessions(user_id) WHERE is_revoked = FALSE;
CREATE INDEX idx_sessions_refresh_token ON user_sessions(refresh_token) WHERE is_revoked = FALSE;

-- Subscriptions & PREMIUM PLANS

CREATE TABLE subscription_plans_catalog (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            subscription_plan NOT NULL UNIQUE,
    display_name    VARCHAR(100) NOT NULL,
    price_monthly   NUMERIC(10,2),
    price_yearly    NUMERIC(10,2),
    features        JSONB,                     
    is_active       BOOLEAN     DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_subscriptions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan_id             UUID        NOT NULL REFERENCES subscription_plans_catalog(id),
    status              subscription_status NOT NULL DEFAULT 'trial',
    started_at          TIMESTAMPTZ DEFAULT NOW(),
    expires_at          TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ,
    trial_ends_at       TIMESTAMPTZ,

    -- Payment provider reference
    provider            VARCHAR(50),               
    provider_sub_id     TEXT UNIQUE,            
    payment_metadata    JSONB,

    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_subscriptions_user    ON user_subscriptions(user_id);
CREATE INDEX idx_subscriptions_status  ON user_subscriptions(status, expires_at);

-- USER SETTINGS (per-user preferences)

CREATE TABLE user_settings (
    user_id                 UUID    PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    theme                   VARCHAR(20) DEFAULT 'system',
    week_start_day          SMALLINT DEFAULT 1,   
    notifications_enabled   BOOLEAN DEFAULT TRUE,
    reminder_default_time   TIME    DEFAULT '08:00:00',
    show_in_leaderboard     BOOLEAN DEFAULT TRUE,
    profile_is_public       BOOLEAN DEFAULT FALSE,
    allow_friend_requests   BOOLEAN DEFAULT TRUE,
    updated_at              TIMESTAMPTZ DEFAULT NOW()
);

-- CATEGORIES

CREATE TABLE categories (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    color       CHAR(7),                           
    icon        VARCHAR(50),
    sort_order  INT         DEFAULT 0,
    deleted_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_categories_user ON categories(user_id) WHERE deleted_at IS NULL;

-- HABITS

CREATE TABLE habits (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id         UUID            REFERENCES categories(id) ON DELETE SET NULL,

    name                VARCHAR(255)    NOT NULL,
    description         TEXT,
    icon                VARCHAR(50),
    color               CHAR(7),

    -- Scheduling
    frequency           habit_frequency NOT NULL DEFAULT 'daily',
    scheduled_days      SMALLINT[],                
    target_count        SMALLINT        DEFAULT 1, 
    target_period_days  SMALLINT        DEFAULT 1, 

    -- Goal type
    goal_type           habit_goal_type DEFAULT 'boolean',
    goal_value          NUMERIC(10,2),             
    goal_unit           VARCHAR(30),               

    -- Reminders
    reminder_enabled    BOOLEAN         DEFAULT FALSE,
    reminder_times      TIME[],                   

    -- Tracking window
    start_date          DATE            NOT NULL DEFAULT CURRENT_DATE,
    end_date            DATE,

    -- State
    is_archived         BOOLEAN         DEFAULT FALSE,
    sort_order          INT             DEFAULT 0,
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     DEFAULT NOW()
);

CREATE INDEX idx_habits_user         ON habits(user_id) WHERE deleted_at IS NULL AND is_archived = FALSE;
CREATE INDEX idx_habits_user_category ON habits(user_id, category_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_habits_name_trgm    ON habits USING gin(name gin_trgm_ops);

-- HABIT COMPLETION LOGS
--  partitioned by month for scalab

CREATE TABLE habit_logs (
    id              UUID        NOT NULL DEFAULT gen_random_uuid(),
    habit_id        UUID        NOT NULL,           
    user_id         UUID        NOT NULL,
    logged_date     DATE        NOT NULL,           
    logged_at       TIMESTAMPTZ DEFAULT NOW(),      

    -- For count
    value           NUMERIC(10,2) DEFAULT 1,        

    note            TEXT,                           
    mood            SMALLINT CHECK (mood BETWEEN 1 AND 5),

    -- Soft delete
    deleted_at      TIMESTAMPTZ,

    PRIMARY KEY (id, logged_date)
) PARTITION BY RANGE (logged_date);

-- Create monthly partitions
CREATE TABLE habit_logs_2024_01 PARTITION OF habit_logs FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE habit_logs_2024_02 PARTITION OF habit_logs FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE habit_logs_2024_03 PARTITION OF habit_logs FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');
CREATE TABLE habit_logs_2024_04 PARTITION OF habit_logs FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
CREATE TABLE habit_logs_2024_05 PARTITION OF habit_logs FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');
CREATE TABLE habit_logs_2024_06 PARTITION OF habit_logs FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');
CREATE TABLE habit_logs_2024_07 PARTITION OF habit_logs FOR VALUES FROM ('2024-07-01') TO ('2024-08-01');
CREATE TABLE habit_logs_2024_08 PARTITION OF habit_logs FOR VALUES FROM ('2024-08-01') TO ('2024-09-01');
CREATE TABLE habit_logs_2024_09 PARTITION OF habit_logs FOR VALUES FROM ('2024-09-01') TO ('2024-10-01');
CREATE TABLE habit_logs_2024_10 PARTITION OF habit_logs FOR VALUES FROM ('2024-10-01') TO ('2024-11-01');
CREATE TABLE habit_logs_2024_11 PARTITION OF habit_logs FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');
CREATE TABLE habit_logs_2024_12 PARTITION OF habit_logs FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');
CREATE TABLE habit_logs_2025_01 PARTITION OF habit_logs FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE habit_logs_2025_02 PARTITION OF habit_logs FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE habit_logs_2025_03 PARTITION OF habit_logs FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE habit_logs_2025_04 PARTITION OF habit_logs FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE habit_logs_2025_05 PARTITION OF habit_logs FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE habit_logs_2025_06 PARTITION OF habit_logs FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE habit_logs_2025_07 PARTITION OF habit_logs FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE habit_logs_2025_08 PARTITION OF habit_logs FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE habit_logs_2025_09 PARTITION OF habit_logs FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE habit_logs_2025_10 PARTITION OF habit_logs FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE habit_logs_2025_11 PARTITION OF habit_logs FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
CREATE TABLE habit_logs_2025_12 PARTITION OF habit_logs FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');
CREATE TABLE habit_logs_2026_01 PARTITION OF habit_logs FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE habit_logs_2026_02 PARTITION OF habit_logs FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE habit_logs_2026_03 PARTITION OF habit_logs FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE habit_logs_default  PARTITION OF habit_logs DEFAULT;

-- Indexes 
CREATE UNIQUE INDEX idx_logs_unique     ON habit_logs(habit_id, logged_date) WHERE deleted_at IS NULL;
CREATE INDEX idx_logs_user_date         ON habit_logs(user_id, logged_date);
CREATE INDEX idx_logs_habit_date        ON habit_logs(habit_id, logged_date DESC);
CREATE INDEX idx_logs_user_month        ON habit_logs(user_id, DATE_TRUNC('month', logged_date));

-- Streaks

CREATE TABLE habit_streaks (
    habit_id            UUID    PRIMARY KEY REFERENCES habits(id) ON DELETE CASCADE,
    current_streak      INT     DEFAULT 0,
    longest_streak      INT     DEFAULT 0,
    last_completed_on   DATE,
    streak_start_date   DATE,
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_streaks_current ON habit_streaks(current_streak DESC);

-- PRECOMPUTED ANALYTICS 

CREATE TABLE habit_analytics (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    habit_id        UUID            NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    user_id         UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    period          analytics_period NOT NULL,
    period_start    DATE            NOT NULL,

    total_days      SMALLINT        DEFAULT 0,  
    completed_days  SMALLINT        DEFAULT 0,  
    completion_rate NUMERIC(5,2)    DEFAULT 0,  
    total_value     NUMERIC(10,2)   DEFAULT 0,  
    avg_value       NUMERIC(10,2),
    best_streak     INT             DEFAULT 0,

    computed_at     TIMESTAMPTZ     DEFAULT NOW(),

    UNIQUE (habit_id, period, period_start)
);

CREATE INDEX idx_analytics_user_period  ON habit_analytics(user_id, period, period_start DESC);
CREATE INDEX idx_analytics_habit_period ON habit_analytics(habit_id, period, period_start DESC);

-- User-level rollup analytics
CREATE TABLE user_analytics (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    period              analytics_period NOT NULL,
    period_start        DATE            NOT NULL,

    total_habits        SMALLINT        DEFAULT 0,
    active_habits       SMALLINT        DEFAULT 0,
    overall_rate        NUMERIC(5,2)    DEFAULT 0,
    total_completions   INT             DEFAULT 0,
    longest_streak_any  INT             DEFAULT 0,  
    points_earned       INT             DEFAULT 0,

    computed_at         TIMESTAMPTZ     DEFAULT NOW(),
    UNIQUE (user_id, period, period_start)
);

CREATE INDEX idx_user_analytics_period ON user_analytics(user_id, period, period_start DESC);

-- POINTS SYSTEM

CREATE TABLE user_points (
    user_id         UUID    PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    total_points    INT     DEFAULT 0,
    level           SMALLINT DEFAULT 1,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_points_leaderboard ON user_points(total_points DESC);

CREATE TABLE points_transactions (
    id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type        points_tx_type  NOT NULL,
    points      INT             NOT NULL,       
    balance_after INT           NOT NULL,
    reason      VARCHAR(255),                 
    ref_type    VARCHAR(50),                   
    ref_id      UUID,                          
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_points_tx_user     ON points_transactions(user_id, created_at DESC);
CREATE INDEX idx_points_tx_type     ON points_transactions(type, created_at DESC);

-- Level thresholds
CREATE TABLE level_config (
    level           SMALLINT    PRIMARY KEY,
    required_points INT         NOT NULL,
    label           VARCHAR(50),              
    badge_icon      VARCHAR(50)
);
-- ACHIEVEMENTS 

CREATE TABLE achievements_catalog (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    type            achievement_type NOT NULL,
    code            VARCHAR(50)     NOT NULL UNIQUE,  
    name            VARCHAR(100)    NOT NULL,
    description     TEXT,
    icon_url        TEXT,
    points_reward   INT             DEFAULT 0,
    criteria        JSONB           NOT NULL,          
    is_secret       BOOLEAN         DEFAULT FALSE,     
    is_active       BOOLEAN         DEFAULT TRUE,
    created_at      TIMESTAMPTZ     DEFAULT NOW()
);

CREATE TABLE user_achievements (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    achievement_id  UUID    NOT NULL REFERENCES achievements_catalog(id),
    habit_id        UUID    REFERENCES habits(id) ON DELETE SET NULL,
    unlocked_at     TIMESTAMPTZ DEFAULT NOW(),
    notified        BOOLEAN DEFAULT FALSE,

    UNIQUE (user_id, achievement_id)
);

CREATE INDEX idx_achievements_user     ON user_achievements(user_id, unlocked_at DESC);
CREATE INDEX idx_achievements_unnotified ON user_achievements(user_id) WHERE notified = FALSE;

-- Socials
CREATE TABLE friendships (
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id    UUID                NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    addressee_id    UUID                NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          friendship_status   NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ         DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         DEFAULT NOW(),

    CONSTRAINT no_self_friend CHECK (requester_id <> addressee_id),
    UNIQUE (requester_id, addressee_id)
);

CREATE INDEX idx_friends_requester  ON friendships(requester_id, status);
CREATE INDEX idx_friends_addressee  ON friendships(addressee_id, status);

--- SOCIAL ACCOUNTABILITY GROUPS

CREATE TABLE groups (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    avatar_url      TEXT,
    invite_code     VARCHAR(20) UNIQUE DEFAULT SUBSTR(MD5(RANDOM()::TEXT), 1, 8),
    is_public       BOOLEAN DEFAULT FALSE,
    max_members     SMALLINT DEFAULT 10,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_groups_invite  ON groups(invite_code) WHERE deleted_at IS NULL;
CREATE INDEX idx_groups_public  ON groups(is_public) WHERE deleted_at IS NULL AND is_public = TRUE;

CREATE TABLE group_members (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role        group_role  NOT NULL DEFAULT 'member',
    joined_at   TIMESTAMPTZ DEFAULT NOW(),
    left_at     TIMESTAMPTZ,

    UNIQUE (group_id, user_id)
);

CREATE INDEX idx_group_members_group ON group_members(group_id) WHERE left_at IS NULL;
CREATE INDEX idx_group_members_user  ON group_members(user_id) WHERE left_at IS NULL;

----- Shared habits within a group 
CREATE TABLE group_habits (
    id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID    NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    habit_id    UUID    NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    added_by    UUID    NOT NULL REFERENCES users(id),
    added_at    TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE (group_id, habit_id)
);

-- Group activity feed
CREATE TABLE group_activity (
    id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID    NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id     UUID    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    activity    VARCHAR(50) NOT NULL,              
    payload     JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_group_activity ON group_activity(group_id, created_at DESC);

------ Social sharings

CREATE TABLE social_shares (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform        share_platform  NOT NULL,
    share_type      VARCHAR(50)     NOT NULL,   
    ref_id          UUID,                        
    shared_image_url TEXT,
    share_token     VARCHAR(32) UNIQUE DEFAULT SUBSTR(MD5(RANDOM()::TEXT), 1, 16),
    view_count      INT DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_shares_user     ON social_shares(user_id, created_at DESC);
CREATE INDEX idx_shares_token    ON social_shares(share_token);

---- Push notifications and tracking

CREATE TABLE push_devices (
    id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       TEXT    NOT NULL UNIQUE,
    platform    VARCHAR(20) NOT NULL,            
    app_version VARCHAR(20),
    is_active   BOOLEAN DEFAULT TRUE,
    last_used   TIMESTAMPTZ DEFAULT NOW(),
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_devices_user   ON push_devices(user_id) WHERE is_active = TRUE;

CREATE TABLE push_notifications (
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID                    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id       UUID                    REFERENCES push_devices(id) ON DELETE SET NULL,
    type            notification_type       NOT NULL,
    status          notification_status     NOT NULL DEFAULT 'pending',
    title           VARCHAR(200),
    body            TEXT,
    payload         JSONB,                         
    scheduled_at    TIMESTAMPTZ             NOT NULL,
    sent_at         TIMESTAMPTZ,
    delivered_at    TIMESTAMPTZ,
    opened_at       TIMESTAMPTZ,
    failed_reason   TEXT,
    created_at      TIMESTAMPTZ             DEFAULT NOW()
);

CREATE INDEX idx_notif_user_status  ON push_notifications(user_id, status);
CREATE INDEX idx_notif_scheduled    ON push_notifications(scheduled_at, status) WHERE status = 'pending';
CREATE INDEX idx_notif_type         ON push_notifications(type, created_at DESC);

----- BACKUPS

CREATE TABLE backups (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    file_path       TEXT        NOT NULL,
    encryption_algo VARCHAR(20) DEFAULT 'AES-256-GCM',
    file_size_bytes BIGINT,
    checksum        TEXT,                          
    is_verified     BOOLEAN     DEFAULT FALSE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_backups_user ON backups(user_id, created_at DESC);


-- AUDIT LOG (security)

CREATE TABLE audit_logs (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        REFERENCES users(id) ON DELETE SET NULL,
    action      VARCHAR(100) NOT NULL,             
    ip_address  INET,
    user_agent  TEXT,
    target_type VARCHAR(50),                       
    target_id   UUID,
    metadata    JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE TABLE audit_logs_2025 PARTITION OF audit_logs
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE audit_logs_2026 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;

CREATE INDEX idx_audit_user     ON audit_logs(user_id, created_at DESC);
CREATE INDEX idx_audit_action   ON audit_logs(action, created_at DESC);
CREATE INDEX idx_audit_ip       ON audit_logs(ip_address, created_at DESC);

-- RATE LIMITING 

CREATE TABLE rate_limit_buckets (
    key             TEXT        NOT NULL,         
    requests        INT         DEFAULT 0,
    window_start    TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (key)
);

CREATE INDEX idx_rate_limit_window ON rate_limit_buckets(window_start);


---- CHALLENGES

CREATE TABLE challenges (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    created_by      UUID    NOT NULL REFERENCES users(id),
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    habit_template  JSONB,                         
    start_date      DATE    NOT NULL,
    end_date        DATE    NOT NULL,
    is_public       BOOLEAN DEFAULT TRUE,
    points_reward   INT     DEFAULT 0,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_challenges_public ON challenges(is_public, start_date) WHERE deleted_at IS NULL;

CREATE TABLE challenge_participants (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_id    UUID    NOT NULL REFERENCES challenges(id) ON DELETE CASCADE,
    user_id         UUID    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    habit_id        UUID    REFERENCES habits(id) ON DELETE SET NULL,
    joined_at       TIMESTAMPTZ DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    rank            INT,

    UNIQUE (challenge_id, user_id)
);

CREATE INDEX idx_challenge_participants ON challenge_participants(challenge_id, joined_at);

-- TRIGGERS


-- Auto-update updated_at on key tables
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_updated         BEFORE UPDATE ON users           FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_habits_updated        BEFORE UPDATE ON habits          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_groups_updated        BEFORE UPDATE ON groups          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_subscriptions_updated BEFORE UPDATE ON user_subscriptions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Automatically update streak 
CREATE OR REPLACE FUNCTION update_streak_on_log()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO habit_streaks (habit_id, last_completed_on, updated_at)
    VALUES (NEW.habit_id, NEW.logged_date, NOW())
    ON CONFLICT (habit_id) DO UPDATE
        SET last_completed_on = GREATEST(habit_streaks.last_completed_on, NEW.logged_date),
            updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_update_streak
AFTER INSERT ON habit_logs
FOR EACH ROW EXECUTE FUNCTION update_streak_on_log();

-- Maintain points
CREATE OR REPLACE FUNCTION check_points_non_negative()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.balance_after < 0 THEN
        RAISE EXCEPTION 'Points balance cannot go below 0. Current: %, Attempted: %',
            (SELECT total_points FROM user_points WHERE user_id = NEW.user_id), NEW.points;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_points
BEFORE INSERT ON points_transactions
FOR EACH ROW EXECUTE FUNCTION check_points_non_negative();

-- VIEWS
-- Active user habits with streak info
CREATE VIEW v_user_habits_with_streaks AS
SELECT
    h.id,
    h.user_id,
    h.name,
    h.frequency,
    h.goal_type,
    h.color,
    h.icon,
    COALESCE(hs.current_streak, 0)  AS current_streak,
    COALESCE(hs.longest_streak, 0)  AS longest_streak,
    hs.last_completed_on,
    h.start_date,
    h.created_at
FROM habits h
LEFT JOIN habit_streaks hs ON hs.habit_id = h.id
WHERE h.deleted_at IS NULL AND h.is_archived = FALSE;

-- Leaderboard views
CREATE VIEW v_leaderboard AS
SELECT
    u.id,
    u.username,
    u.display_name,
    u.avatar_url,
    up.total_points,
    up.level,
    lc.label AS level_label,
    RANK() OVER (ORDER BY up.total_points DESC) AS rank
FROM user_points up
JOIN users u ON u.id = up.user_id
LEFT JOIN level_config lc ON lc.level = up.level
WHERE u.deleted_at IS NULL
  AND EXISTS (
      SELECT 1 FROM user_settings us
      WHERE us.user_id = u.id AND us.show_in_leaderboard = TRUE
  );

---- Today's habit completion status 
CREATE VIEW v_today_habits AS
SELECT
    h.user_id,
    h.id     AS habit_id,
    h.name,
    h.color,
    h.icon,
    h.frequency,
    CASE WHEN hl.id IS NOT NULL THEN TRUE ELSE FALSE END AS completed_today,
    hl.value AS today_value
FROM habits h
LEFT JOIN habit_logs hl
    ON hl.habit_id = h.id
   AND hl.logged_date = CURRENT_DATE
   AND hl.deleted_at IS NULL
WHERE h.deleted_at IS NULL AND h.is_archived = FALSE;

-- ROW LEVEL SECURITY (prevent users from accessing each other's datas )

ALTER TABLE habits          ENABLE ROW LEVEL SECURITY;
ALTER TABLE habit_logs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories      ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_settings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE backups         ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_achievements ENABLE ROW LEVEL SECURITY;

---- Application connects as 'app_user' 
CREATE ROLE app_user;

CREATE POLICY habits_owner_policy ON habits
    FOR ALL TO app_user
    USING (user_id = current_setting('app.current_user_id')::UUID);

CREATE POLICY logs_owner_policy ON habit_logs
    FOR ALL TO app_user
    USING (user_id = current_setting('app.current_user_id')::UUID);

CREATE POLICY categories_owner_policy ON categories
    FOR ALL TO app_user
    USING (user_id = current_setting('app.current_user_id')::UUID);

CREATE POLICY settings_owner_policy ON user_settings
    FOR ALL TO app_user
    USING (user_id = current_setting('app.current_user_id')::UUID);

-- SEED DATA: Subscription Plans

INSERT INTO subscription_plans_catalog (name, display_name, price_monthly, price_yearly, features) VALUES
('free',  'Free',    0,     0,       '{"max_habits": 5, "heatmap": false, "analytics": false, "backup": false}'),
('pro',   'Pro',     2.99,  24.99,   '{"max_habits": 50, "heatmap": true, "analytics": true, "backup": true}'),
('team',  'Team',    9.99,  79.99,   '{"max_habits": -1, "heatmap": true, "analytics": true, "backup": true, "groups": true}');

-- Seed Levels
INSERT INTO level_config (level, required_points, label, badge_icon) VALUES
(1,  0,     'Beginner',    'seed'),
(2,  100,   'Starter',     'sprout'),
(3,  300,   'Consistent',  'leaf'),
(4,  700,   'Focused',     'flame'),
(5,  1500,  'Dedicated',   'star'),
(6,  3000,  'Champion',    'trophy'),
(7,  6000,  'Legend',      'crown');

-- Seed Achievements
INSERT INTO achievements_catalog (type, code, name, description, points_reward, criteria) VALUES
('streak',     'streak_3',       '3-Day Streak',        'Complete a habit 3 days in a row',       10,  '{"streak_days": 3}'),
('streak',     'streak_7',       'Week Warrior',        'Complete a habit 7 days in a row',       25,  '{"streak_days": 7}'),
('streak',     'streak_30',      'Monthly Master',      'Complete a habit 30 days in a row',      100, '{"streak_days": 30}'),
('streak',     'streak_100',     'Century Streak',      '100 days without breaking the chain',    500, '{"streak_days": 100}'),
('completion', 'habit_first',    'First Step',          'Complete your first habit',              5,   '{"completions": 1}'),
('completion', 'habit_50',       '50 Completions',      'Log a habit 50 times total',             50,  '{"completions": 50}'),
('completion', 'habit_500',      '500 Club',            'Log habits 500 times total',             200, '{"completions": 500}'),
('social',     'first_friend',   'Social Butterfly',    'Add your first friend',                  15,  '{"friends": 1}'),
('social',     'group_create',   'Team Player',         'Create an accountability group',         20,  '{"groups_created": 1}'),
('special',    'early_adopter',  'Early Adopter',       'One of the first 1000 users',            100, '{"user_number_max": 1000}'),
('special',    'perfect_week',   'Perfect Week',        'Complete all habits for 7 days straight',75,  '{"perfect_days": 7}');



/*
-- Get today's habits with completion status for a user:
SELECT * FROM v_today_habits WHERE user_id = $1;

-- Get habit heatmap data (last 365 days):
SELECT logged_date, COUNT(*) AS completions
FROM habit_logs
WHERE habit_id = $1
  AND logged_date >= CURRENT_DATE - INTERVAL '365 days'
  AND deleted_at IS NULL
GROUP BY logged_date
ORDER BY logged_date;

-- Get user analytics for last 30 days (uses precomputed table):
SELECT *
FROM habit_analytics
WHERE user_id = $1
  AND period = 'daily'
  AND period_start >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY period_start DESC;

-- Top 10 leaderboard:
SELECT * FROM v_leaderboard LIMIT 10;

-- Friends' recent completions (social feed):
SELECT u.username, u.avatar_url, h.name AS habit_name, hl.logged_date
FROM habit_logs hl
JOIN habits h ON h.id = hl.habit_id
JOIN users u ON u.id = hl.user_id
WHERE hl.user_id IN (
    SELECT CASE WHEN requester_id = $1 THEN addressee_id ELSE requester_id END
    FROM friendships
    WHERE (requester_id = $1 OR addressee_id = $1) AND status = 'accepted'
)
  AND hl.logged_date >= CURRENT_DATE - INTERVAL '7 days'
  AND hl.deleted_at IS NULL
ORDER BY hl.logged_at DESC
LIMIT 50;

-- Check unnotified achievements:
SELECT ua.*, ac.name, ac.description, ac.icon_url, ac.points_reward
FROM user_achievements ua
JOIN achievements_catalog ac ON ac.id = ua.achievement_id
WHERE ua.user_id = $1 AND ua.notified = FALSE;
*/