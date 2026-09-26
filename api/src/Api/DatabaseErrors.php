<?php

declare(strict_types=1);

namespace App\Api;

use Doctrine\DBAL\Exception\DriverException;
use Throwable;

/**
 * The database raises the contract's errors itself: `private.raise_error` sets SQLSTATE to PT plus
 * the HTTP status, the message to the code, the detail to the JSON the client reads and the hint to
 * a sentence for a person. Supabase let PostgREST turn that into a response; here it is this class.
 *
 * Anything else — a constraint the functions did not catch, a connection that dropped — stays a
 * server error and is logged, because it is a bug in this server and not an answer to the client.
 */
final class DatabaseErrors
{
    public static function toApiError(Throwable $error): ApiError
    {
        $raised = self::raised($error);
        if (null !== $raised) {
            return $raised;
        }

        return new ApiError('SERVER_ERROR', 'The café database could not answer that.', [], 500, $error);
    }

    /** The error the database raised on purpose, or null when it did not raise one of ours. */
    public static function raised(Throwable $error): ?ApiError
    {
        $state = self::sqlState($error);

        // A policy refused the row, or a grant is missing. Most writes go through a function that
        // raises its own FORBIDDEN, but a category added or deleted is a plain statement whose only
        // guard is the policy on the table, and Postgres answers both cases with one state. Either
        // way what it means is the contract's FORBIDDEN: this role cannot do that. PostgREST turned
        // 42501 into 403 too, when the café ran on Supabase, so the answer is the one it always was.
        if ('42501' === $state) {
            return ApiError::forbidden('Your role cannot do this.');
        }

        if (null === $state || !preg_match('/^PT(\d{3})$/', $state, $status)) {
            return null;
        }

        $text = $error->getMessage();
        if (!preg_match('/ERROR:\s*(?<code>[A-Z_]+)/', $text, $code)) {
            return null;
        }

        return new ApiError(
            errorCode: $code['code'],
            message: self::part($text, 'HINT') ?? 'The café database refused that.',
            details: self::details($text),
            status: (int) $status[1],
            previous: $error,
        );
    }

    private static function sqlState(Throwable $error): ?string
    {
        for ($current = $error; null !== $current; $current = $current->getPrevious()) {
            if ($current instanceof DriverException) {
                return $current->getSQLState();
            }
            if (preg_match('/SQLSTATE\[(\w{5})\]/', $current->getMessage(), $found)) {
                return $found[1];
            }
        }

        return null;
    }

    private static function details(string $text): array
    {
        $detail = self::part($text, 'DETAIL');
        if (null === $detail) {
            return [];
        }

        $decoded = json_decode($detail, true);

        return is_array($decoded) ? $decoded : [];
    }

    /** One field of the raised error: everything after `DETAIL:` or `HINT:` up to the next one. */
    private static function part(string $text, string $name): ?string
    {
        $pattern = sprintf('/%s:\s*(?<value>.*?)(?=\s*(?:DETAIL|HINT|CONTEXT|STATEMENT):|$)/s', $name);

        return preg_match($pattern, $text, $found) ? trim($found['value']) : null;
    }
}
