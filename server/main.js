const fs = require('fs');
const path = require('path');
const initSqlJs = require('sql.js');

const resourceName = GetCurrentResourceName();
const resourcePath = GetResourcePath(resourceName);

const configPath = path.join(resourcePath, 'config.json');
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

const dbPath = path.join(resourcePath, config.dbFileName || 'spawn_data.sqlite3');

let SQL;
let db;
let dbReady = false;

// Players who have landed at their real spot. Until then the ped is wherever
// spawnmanager parked it during loading, so no position from them is saved.
const spawnedPlayers = new Set();

function getPrimaryIdentifier(playerId) {
    let ids = [];

    if (typeof GetNumPlayerIdentifiers === 'function' && typeof GetPlayerIdentifier === 'function') {
        const count = Number(GetNumPlayerIdentifiers(playerId)) || 0;
        for (let i = 0; i < count; i += 1) {
            const identifier = GetPlayerIdentifier(playerId, i);
            if (identifier) {
                ids.push(identifier);
            }
        }
    } else if (typeof getPlayerIdentifiers === 'function') {
        ids = getPlayerIdentifiers(playerId) || [];
    }

    if (!ids || ids.length === 0) {
        return null;
    }

    const preferredPrefixes = ['license:', 'fivem:', 'discord:', 'steam:'];

    for (const prefix of preferredPrefixes) {
        const found = ids.find((id) => id.startsWith(prefix));
        if (found) {
            return found;
        }
    }

    return ids[0];
}

function persistDbToDisk() {
    if (!dbReady || !db) {
        return;
    }

    const data = db.export();
    fs.writeFileSync(dbPath, Buffer.from(data));
}

function ensureDatabase() {
    db.run(`
        CREATE TABLE IF NOT EXISTS player_spawns (
            identifier TEXT PRIMARY KEY,
            x REAL NOT NULL,
            y REAL NOT NULL,
            z REAL NOT NULL,
            heading REAL NOT NULL,
            updated_at INTEGER NOT NULL
        );
    `);

    persistDbToDisk();
}

function getSavedSpawn(identifier) {
    const stmt = db.prepare(
        'SELECT x, y, z, heading FROM player_spawns WHERE identifier = ? LIMIT 1;'
    );

    stmt.bind([identifier]);

    let row = null;
    if (stmt.step()) {
        row = stmt.getAsObject();
    }

    stmt.free();
    return row;
}

function upsertSpawn(identifier, x, y, z, heading) {
    const stmt = db.prepare(`
        INSERT INTO player_spawns (identifier, x, y, z, heading, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(identifier) DO UPDATE SET
            x = excluded.x,
            y = excluded.y,
            z = excluded.z,
            heading = excluded.heading,
            updated_at = excluded.updated_at;
    `);

    stmt.run([identifier, x, y, z, heading, Date.now()]);
    stmt.free();

    persistDbToDisk();
}

function saveCurrentPlayerSpawn(playerId) {
    if (!dbReady) {
        return { ok: false, reason: 'db_not_ready' };
    }

    const identifier = getPrimaryIdentifier(playerId);
    if (!identifier) {
        return { ok: false, reason: 'identifier_missing' };
    }

    const ped = GetPlayerPed(playerId);
    if (!ped || ped === 0) {
        return { ok: false, reason: 'ped_missing' };
    }

    const [x, y, z] = GetEntityCoords(ped);
    const heading = GetEntityHeading(ped);

    upsertSpawn(identifier, x, y, z, heading);
    return { ok: true, x, y, z, heading };
}

async function initDatabase() {
    SQL = await initSqlJs({
        locateFile: (fileName) => path.join(resourcePath, 'node_modules', 'sql.js', 'dist', fileName)
    });

    if (fs.existsSync(dbPath)) {
        const fileData = fs.readFileSync(dbPath);
        db = new SQL.Database(fileData);
    } else {
        db = new SQL.Database();
    }

    ensureDatabase();
    dbReady = true;

    console.log(`[${resourceName}] SQLite ready: ${dbPath}`);
}

onNet('persistentspawn:server:requestSpawn', () => {
    const sourcePlayer = global.source;
    spawnedPlayers.delete(String(sourcePlayer));

    if (!dbReady) {
        emitNet('persistentspawn:client:applySpawn', sourcePlayer, config.defaultSpawn);
        return;
    }

    const identifier = getPrimaryIdentifier(sourcePlayer);
    if (!identifier) {
        emitNet('persistentspawn:client:applySpawn', sourcePlayer, config.defaultSpawn);
        return;
    }

    const saved = getSavedSpawn(identifier);
    if (saved) {
        emitNet('persistentspawn:client:applySpawn', sourcePlayer, {
            x: Number(saved.x),
            y: Number(saved.y),
            z: Number(saved.z),
            heading: Number(saved.heading)
        });
        return;
    }

    emitNet('persistentspawn:client:applySpawn', sourcePlayer, config.defaultSpawn);
});

onNet('persistentspawn:server:spawnComplete', () => {
    spawnedPlayers.add(String(global.source));
});

onNet('persistentspawn:server:saveSpawn', (spawn) => {
    const sourcePlayer = global.source;

    if (!dbReady || !spawn || !spawnedPlayers.has(String(sourcePlayer))) {
        return;
    }

    const identifier = getPrimaryIdentifier(sourcePlayer);
    if (!identifier) {
        return;
    }

    const x = Number(spawn.x);
    const y = Number(spawn.y);
    const z = Number(spawn.z);
    const heading = Number(spawn.heading || 0.0);

    if ([x, y, z, heading].some((value) => Number.isNaN(value))) {
        return;
    }

    upsertSpawn(identifier, x, y, z, heading);
});

RegisterCommand('setspawn', (sourcePlayer) => {
    if (!sourcePlayer || sourcePlayer <= 0) {
        return;
    }

    const result = saveCurrentPlayerSpawn(sourcePlayer);

    if (!result.ok) {
        emitNet('chat:addMessage', sourcePlayer, {
            color: [220, 53, 69],
            args: ['Persistent Spawn', 'Could not save your spawn right now.']
        });
        return;
    }

    emitNet('chat:addMessage', sourcePlayer, {
        color: [46, 204, 113],
        args: ['Persistent Spawn', 'Spawn saved to your current location.']
    });
}, false);

on('playerDropped', () => {
    const sourcePlayer = global.source;
    const wasSpawned = spawnedPlayers.delete(String(sourcePlayer));

    if (!dbReady || !wasSpawned) {
        return;
    }

    const identifier = getPrimaryIdentifier(sourcePlayer);
    if (!identifier) {
        return;
    }

    const ped = GetPlayerPed(sourcePlayer);
    if (!ped || ped === 0) {
        return;
    }

    const [x, y, z] = GetEntityCoords(ped);
    const heading = GetEntityHeading(ped);

    upsertSpawn(identifier, x, y, z, heading);
});

on('onResourceStop', (stoppedResourceName) => {
    if (stoppedResourceName !== resourceName) {
        return;
    }

    if (dbReady) {
        persistDbToDisk();
    }
});

initDatabase().catch((error) => {
    console.error(`[${resourceName}] Failed to init SQLite:`, error);
});
