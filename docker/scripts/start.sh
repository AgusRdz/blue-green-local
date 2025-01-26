#!/bin/bash
php-fpm &
supervisord -c /etc/supervisor/supervisord.conf
wait -n
