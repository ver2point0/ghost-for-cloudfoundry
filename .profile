#!/bin/bash

set -eux

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$ROOT"

if [[ "${CF_INSTANCE_INDEX:-0}" != "0" ]]; then
    2&> echo "Ghost only supports one app instance. I don't know why."
    exit 1
fi

source bin/source_cf_env.sh
mysqluri=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .credentials.uri' | sed -e "s/\?.*//")
# the 'sed' will strip ?reconnect from mysql://u:p@host:3306/dbname?reconnect=true
mysqlhost=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .credentials.hostname')
mysqlport=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .credentials.port')
mysqlusername=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .credentials.username')
mysqlpassword=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .credentials.password')
mysqldatabase=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .credentials.name')
cleardb_plan=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-mysql"))[0] .plan')
cleardb_max_conn=10
if [[ "${cleardb_plan}" == "spark" ]]; then
  cleardb_max_conn=3
fi

mailservice=sendgrid
mailhostname=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-email"))[0] .credentials.hostname')
mailusername=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-email"))[0] .credentials.username')
mailpassword=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-email"))[0] .credentials.password')

aws_access_key_id=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-s3"))[0] .credentials.access_key_id')
aws_secret_access_key=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-s3"))[0] .credentials.secret_access_key')
aws_bucket=$(echo "$VCAP_SERVICES" | jq -r '.[]|select(any(.name == "ghost-s3"))[0] .credentials.bucket')
aws_region=$(echo "$VCAP_SERVICES" | jq -r ".[]|select(any(.name == \"ghost-s3\"))[0] | (.credentials.region // \"us-east-1\")")

# Pick the shortest route, which will be the starkandwayne.com/path version, rather than
# www.starkandwyane.com/path. The shorter will be more flexible with cross-origin.
appurl=$(echo $VCAP_APPLICATION| jq -r ".uris[]" | awk '{ print length, $0 }' | sort -n -s | cut -d" " -f2- | head -n1)

cat > config.production.json <<-JSON
{
  "url": "https://${appurl}/",
  "server": {
    "port": ${PORT:-8080},
    "host": "0.0.0.0"
  },
  "database": {
    "client": "mysql",
    "connection": {
      "host":     "${mysqlhost}",
      "port":     ${mysqlport},
      "user":     "${mysqlusername}",
      "password": "${mysqlpassword}",
      "database": "${mysqldatabase}"
    },
    "pool": {
      "min": 2,
      "max": ${cleardb_max_conn}
    }
  },
  "mail": {
    "transport": "SMTP",
    "from": "'Dr Nic Williams' <drnic@starkandwayne.com>",
    "options": {
        "service": "${mailservice}",
        "host": "${mailhostname}",
        "auth": {
            "user": "${mailusername}",
            "pass": "${mailpassword}"
        }
    }
  },
  "storage": {
    "active": "s3",
    "s3": {
      "accessKeyId": "${aws_access_key_id}",
      "secretAccessKey": "${aws_secret_access_key}",
      "region": "${aws_region}",
      "bucket": "${aws_bucket}"
    }
  },
  "logging": {
    "transports": [
      "stdout"
    ]
  },
  "process": "local",
  "paths": {
    "contentPath": "${ROOT}/content"
  }
}
JSON

# Not sure what this is for; but node index fails without it
cat > config.channels.json <<-JSON
{
    "index": {
        "route": "/",
        "frontPageTemplate": "home"
    },
    "tag": {
        "route": "/:t_tag/:slug/",
        "postOptions": {
            "filter": "tags:'%s'+tags.visibility:public"
        },
        "data": {
            "tag": {
                "type": "read",
                "resource": "tags",
                "options": {
                    "slug": "%s",
                    "visibility": "public"
                }
            }
        },
        "slugTemplate": true,
        "editRedirect": "#/settings/tags/:slug/"
    },
    "author": {
        "route": "/:t_author/:slug/",
        "postOptions": {
            "filter": "author:'%s'"
        },
        "data": {
            "author": {
                "type": "read",
                "resource": "users",
                "options": {
                    "slug": "%s"
                }
            }
        },
        "slugTemplate": true,
        "editRedirect": "#/team/:slug/"
    }
}
JSON

export NODE_ENV=production

echo "Setting up symlinks"
rm -f current
ln -s versions/* current
(
  cd content/themes/
  rm -rf casper
  ln -s ../../current/content/themes/casper/
)

ls -al
cp -r node_modules current/
cp -r content/data/redirects.json current/content/data/
cp config.production.json current/

export PATH=$PATH:/home/vcap/deps/0/node/bin

if [[ "$(which mysqlsh)X" == "X" ]]; then
    >&2 echo "Please install mysqlsh (aka mysql-shell) to allow clearing of locks"
else
    set +e
    migrations_table_count=$(mysqlsh --uri $mysqluri --sql -e"select count(*) from information_schema.tables where table_schema='$mysqldatabase' and table_name='migrations_lock'"|tail -n 1)
    if [[ "$migrations_table_count" != 0 ]]; then
        echo "Displaying current migrations_lock status"
        mysqlsh --uri $mysqluri --sql -e "select * from migrations_lock;"
        
        echo "Unlocking migrations_lock"
        mysqlsh --uri $mysqluri --sql -e "UPDATE migrations_lock set locked=0 where lock_key='km01';"
        set -e
    fi
fi

(
  set -x

  cd current

  echo "Setup ghost"
  knex-migrator init
  knex-migrator migrate
)

echo "Ensuring root folder before starting app.."
cd "$ROOT"
