<?php
/**
 * Plugin Name: wpd mail to Mailpit
 * Description: Routes all outgoing mail to this site's Mailpit container (https://mail.<site>.test). Nothing leaves your machine.
 */
add_filter('action_scheduler_queue_runner_concurrent_batches', '__return_zero');   // cron is off; stop the async loopback runner
add_action('phpmailer_init', function ($mailer) {
    $mailer->isSMTP();
    $mailer->Host = getenv('WPD_MAIL_HOST') ?: 'mailpit';
    $mailer->Port = 1025;
    $mailer->SMTPAuth = false;
    $mailer->SMTPAutoTLS = false;
    $mailer->SMTPSecure = '';
}, PHP_INT_MAX);   // plugins load after mu-plugins, so run last
