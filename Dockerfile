FROM harbor.asakta.cloud/test/gis-preprod@sha256:85637c11a308b4e0726a77082af69ecf146228c06261f54ce80fe5b2c1256ee4 AS builder

USER frappe
WORKDIR /home/frappe/frappe-bench

ENV PYTHONDONTWRITEBYTECODE=1

ARG SITE_NAME
ARG REDIS_QUEUE
ARG REDIS_CACHE
ARG REDIS_SOCKETIO

ENV SITE_NAME=${SITE_NAME}
ENV REDIS_QUEUE=${REDIS_QUEUE}
ENV REDIS_CACHE=${REDIS_CACHE}
ENV REDIS_SOCKETIO=${REDIS_SOCKETIO}

RUN bench set-config -g server_script_enabled 1 \
 && bench set-config -g redis_queue "${REDIS_QUEUE}" \
 && bench set-config -g redis_cache "${REDIS_CACHE}" \
 && bench set-config -g redis_socketio "${REDIS_SOCKETIO}"

RUN bench use ${SITE_NAME}

RUN bench get-app https://qasim:glpat-sa2V_gaDMsfbiC84GRSUg286MQp1OmgH.01.0w0eluw9d@gitlab.asakta.com/asakta/survey-v2.git --branch main
RUN bench get-app https://qasim:glpat-sa2V_gaDMsfbiC84GRSUg286MQp1OmgH.01.0w0eluw9d@gitlab.asakta.com/asakta/commit.git --branch main
RUN bench get-app https://qasim:glpat-sa2V_gaDMsfbiC84GRSUg286MQp1OmgH.01.0w0eluw9d@gitlab.asakta.com/asakta/frappe_dfp_minio.git --branch main
RUN bench get-app https://qasim:glpat-sa2V_gaDMsfbiC84GRSUg286MQp1OmgH.01.0w0eluw9d@gitlab.asakta.com/asakta/frappe-extensions.git --branch main

RUN bench install-app frappe_extensions
RUN bench install-app commit
RUN bench install-app dfp_external_storage
RUN bench install-app survey_v2

ARG CACHE_BUST
RUN echo "Cache bust: $CACHE_BUST"

RUN cd apps/survey_v2 && git pull \
 && cd ../dfp_external_storage && git pull \
 && cd ../commit && git pull \
 && cd ../frappe_extensions && git pull

 RUN bench pip install --no-cache-dir --upgrade pyOpenSSL cryptography \
 && bench pip install --no-cache-dir firebase-admin==7.1.0

RUN bench migrate
RUN bench clear-cache
RUN bench build --production

RUN rm -rf apps/commit/node_modules
RUN rm -rf apps/commit/dashboard/node_modules
RUN rm -rf apps/commit/docs/node_modules
RUN rm -rf apps/frappe_extensions/node_modules
RUN rm -rf apps/survey_v2/node_modules
RUN rm -rf apps/dfp_external_storage/node_modules

FROM python:3.11.6-slim-bookworm AS final

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
    nginx redis-tools gettext-base wget gpg git nodejs rsync file \
    libpango-1.0-0 libharfbuzz0b libpangocairo-1.0-0 vim \
 && wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install --no-install-recommends -y postgresql-client-16 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash -u 1000 frappe

USER root

RUN pip3 install frappe-bench

COPY ci/nginx-template.conf /templates/nginx/frappe.conf.template
COPY ci/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh

RUN sed -i 's/\r$//' /usr/local/bin/nginx-entrypoint.sh \
 && sed -i 's/\r$//' /templates/nginx/frappe.conf.template \
 && sed -i '/user www-data/d' /etc/nginx/nginx.conf || true \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && touch /run/nginx.pid \
 && mkdir -p /etc/nginx/conf.d \
 && chown -R frappe:frappe /etc/nginx/conf.d /var/log/nginx /var/lib/nginx /run/nginx.pid \
 && chmod 755 /usr/local/bin/nginx-entrypoint.sh \
 && chmod 644 /templates/nginx/frappe.conf.template \
 && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 

USER frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench 

ENV PATH="/home/frappe/frappe-bench/env/bin:/home/frappe/.local/bin:$PATH"

WORKDIR /home/frappe/frappe-bench

VOLUME ["/home/frappe/frappe-bench/logs"]

CMD ["env", "PYTHONPATH=/home/frappe/frappe-bench/apps", "/home/frappe/frappe-bench/env/bin/gunicorn", "--chdir=/home/frappe/frappe-bench/sites", "--bind=0.0.0.0:8000", "--threads=4", "--workers=5", "--worker-class=gthread", "--worker-tmp-dir=/dev/shm", "--timeout=120", "--preload", "frappe.app:application"]
