// openeverest-database-tools: MongoDB initialization, run with `mongosh --nodb --file`.
// Settings come from /scripts/config.json (rendered by the chart); credentials only come
// from environment variables filled from Secrets, so they are never part of a script.
const oedtConfig = JSON.parse(require('fs').readFileSync('/scripts/config.json', 'utf8'));
const oedtEnv = process.env;

const oedtParams = ['authSource=' + encodeURIComponent(oedtConfig.authDatabase), 'serverSelectionTimeoutMS=10000'];
if (oedtConfig.uriOptions) {
  oedtParams.push(oedtConfig.uriOptions);
}
const oedtAddress = oedtEnv.MONGO_HOST + (oedtEnv.MONGO_PORT ? ':' + oedtEnv.MONGO_PORT : '');
const oedtUri = 'mongodb://' + encodeURIComponent(oedtEnv.MONGO_USER) + ':' + encodeURIComponent(oedtEnv.MONGO_PASSWORD) +
  '@' + oedtAddress + '/?' + oedtParams.join('&');

print('=== MongoDB initialization (DatabaseCluster ' + oedtEnv.CLUSTER_NAME + ') ===');

// Retry until the admin user can log in: the DatabaseCluster may report ready before its service routes traffic.
const oedtDeadline = Date.now() + oedtConfig.connectTimeoutSeconds * 1000;
let oedtConn = null;
while (oedtConn === null) {
  try {
    const candidate = Mongo(oedtUri);
    candidate.getDB('admin').runCommand({ ping: 1 });
    oedtConn = candidate;
  } catch (e) {
    if (Date.now() >= oedtDeadline) {
      print('Timed out connecting to MongoDB at ' + oedtAddress + ': ' + e.message);
      quit(1);
    }
    print('Waiting for MongoDB at ' + oedtAddress + ' (' + e.message + ')');
    sleep(5000);
  }
}

// MongoDB creates a database on its first write (a collection below, or the application).
for (const name of oedtConfig.databases) {
  print("Database '" + name + "' is created by MongoDB on its first write");
}

// Users: created in each of their databases (authSource = that database) with the configured roles on it.
for (const user of oedtConfig.users) {
  const username = oedtEnv['APP_USERNAME_' + user.index];
  const password = oedtEnv['APP_PASSWORD_' + user.index];
  for (const dbName of user.databases) {
    const target = oedtConn.getDB(dbName);
    const roles = [];
    for (const role of user.roles) {
      roles.push({ role: role, db: dbName });
    }
    if (target.getUser(username)) {
      if (oedtConfig.updateUserPasswords) {
        target.updateUser(username, { pwd: password });
      }
      target.grantRolesToUser(username, roles);
      print("User '" + username + "' updated on '" + dbName + "'");
    } else {
      target.createUser({ user: username, pwd: password, roles: roles });
      print("User '" + username + "' created on '" + dbName + "'");
    }
  }
}

for (const collection of oedtConfig.collections) {
  const target = oedtConn.getDB(collection.database);
  if (target.getCollectionNames().indexOf(collection.name) === -1) {
    target.createCollection(collection.name);
    print("Collection '" + collection.database + '.' + collection.name + "' created");
  } else {
    print("Collection '" + collection.database + '.' + collection.name + "' already exists");
  }
}

// Init scripts run with `db` bound to initScriptsDatabase (switch with db = db.getSiblingDB('other')).
for (let i = 0; i < oedtConfig.initScripts; i++) {
  print('Running init script ' + (i + 1) + '/' + oedtConfig.initScripts + " on '" + oedtConfig.initScriptsDatabase + "'");
  db = oedtConn.getDB(oedtConfig.initScriptsDatabase);
  load('/scripts/script-' + i + '.js');
}

print('=== MongoDB initialization complete ===');
