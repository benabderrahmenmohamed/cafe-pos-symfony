<?php

declare(strict_types=1);

namespace App\Demo;

use Doctrine\DBAL\Connection;

/**
 * The café a fresh database starts with: Café de la Marsa, its members, its room and its menu, plus
 * a second shop that owns nothing but rows of its own — what the isolation tests read when they
 * check that one café never sees another's.
 *
 * Its ids, names and passwords are the ones the documents, the tests and the screenshots use, and the
 * in-browser demo repeats (src/adapters/memory/seed.ts), so they keep meaning what they say. Passwords are hashed here rather than in SQL: hashing is
 * the application's job now, and Postgres has no business knowing how it is done.
 */
final readonly class DemoSeeder
{
    public const SHOP = '11111111-1111-4111-8111-111111111111';
    public const OTHER_SHOP = '22222222-2222-4222-8222-222222222222';

    /** email => [id, display name, roles, shop, password] */
    public const MEMBERS = [
        'admin@demo.local' => ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'Demo Admin', ['admin'], self::SHOP, 'demo-admin-2026'],
        'cashier@demo.local' => ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'Demo Cashier', ['cashier'], self::SHOP, 'demo-cashier-2026'],
        'waiter@demo.local' => ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3', 'Demo Waiter', ['waiter'], self::SHOP, 'demo-waiter-2026'],
        'kitchen@demo.local' => ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4', 'Demo Kitchen', ['kitchen'], self::SHOP, 'demo-kitchen-2026'],
        'owner@demo.local' => ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5', 'Demo Owner', ['admin', 'cashier'], self::SHOP, 'demo-owner-2026'],
        'other-admin@demo.local' => ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'Other Admin', ['admin'], self::OTHER_SHOP, 'other-admin-2026'],
        'other-cashier@demo.local' => ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2', 'Other Cashier', ['cashier'], self::OTHER_SHOP, 'other-cashier-2026'],
        'other-waiter@demo.local' => ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3', 'Other Waiter', ['waiter'], self::OTHER_SHOP, 'other-waiter-2026'],
    ];

    private const TABLES = [
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'Table 1', 1],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd02', 'Table 2', 2],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd03', 'Table 3', 3],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd04', 'Table 4', 4],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd05', 'Terrasse 1', 5],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd06', 'Terrasse 2', 6],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd07', 'Terrasse 3', 7],
        ['dddddddd-dddd-4ddd-8ddd-dddddddddd08', 'Comptoir', 8],
    ];

    private const CATEGORIES = [
        ['44444444-4444-4444-8444-444444444401', 'Boissons fraîches', '#3b82f6'],
        ['44444444-4444-4444-8444-444444444402', 'Boissons chaudes', '#10b981'],
        ['44444444-4444-4444-8444-444444444403', 'Snacks', '#f59e0b'],
        ['44444444-4444-4444-8444-444444444404', 'Pâtisserie', '#ef4444'],
    ];

    /** id, category, name, millimes, barcode, counted, opening stock */
    private const PRODUCTS = [
        ['55555555-5555-4555-8555-555555555501', '44444444-4444-4444-8444-444444444401', 'Eau minérale 50 cl', 850, '6194000100015', true, 120],
        ['55555555-5555-4555-8555-555555555502', '44444444-4444-4444-8444-444444444401', 'Boisson gazeuse 33 cl', 1350, '6194000200012', true, 60],
        ['55555555-5555-4555-8555-555555555503', '44444444-4444-4444-8444-444444444401', 'Eau minérale 1,5 L', 1900, '6194000200029', true, 8],
        ['55555555-5555-4555-8555-555555555504', '44444444-4444-4444-8444-444444444401', "Jus d'orange en brique", 2450, '6194000300019', true, 40],
        ['55555555-5555-4555-8555-555555555505', '44444444-4444-4444-8444-444444444402', 'Express', 1200, null, false, 0],
        ['55555555-5555-4555-8555-555555555506', '44444444-4444-4444-8444-444444444402', 'Capucin', 1800, null, false, 0],
        ['55555555-5555-4555-8555-555555555507', '44444444-4444-4444-8444-444444444402', 'Direct', 2000, null, false, 0],
        ['55555555-5555-4555-8555-555555555508', '44444444-4444-4444-8444-444444444402', 'Thé à la menthe', 1500, null, false, 0],
        ['55555555-5555-4555-8555-555555555509', '44444444-4444-4444-8444-444444444401', 'Citronnade', 3500, null, false, 0],
        ['55555555-5555-4555-8555-555555555510', '44444444-4444-4444-8444-444444444404', 'Croissant', 1200, null, false, 0],
        ['55555555-5555-4555-8555-555555555511', '44444444-4444-4444-8444-444444444404', 'Mille-feuille', 2600, null, false, 0],
        ['55555555-5555-4555-8555-555555555512', '44444444-4444-4444-8444-444444444403', 'Sandwich thon', 5500, null, false, 0],
    ];

    private const OTHER_PRODUCTS = [
        ['66666666-6666-4666-8666-666666666601', 'Other product A', 1000, '9990000000011', 10],
        ['66666666-6666-4666-8666-666666666602', 'Other product B', 2500, '9990000000028', 10],
    ];

    private const TERMINALS = [
        ['33333333-3333-4333-8333-333333333331', self::SHOP, 'C1'],
        ['33333333-3333-4333-8333-333333333333', self::SHOP, 'S1'],
        ['33333333-3333-4333-8333-333333333332', self::OTHER_SHOP, 'C1'],
    ];

    /** True when the café is already there, so seeding twice is refused rather than doubled. */
    public function isSeeded(Connection $admin): bool
    {
        return (bool) $admin->fetchOne('select exists (select 1 from public.shops where id = ?)', [self::SHOP]);
    }

    public function seed(Connection $admin): void
    {
        $admin->transactional(function (Connection $db): void {
            $db->executeStatement(
                "insert into public.shops (id, name) values (?, 'Café de la Marsa'), (?, 'Other Shop')",
                [self::SHOP, self::OTHER_SHOP],
            );

            foreach (self::MEMBERS as $email => [$id, $name, $roles, $shop, $password]) {
                $db->executeStatement(
                    'insert into public.users (id, email, password_hash) values (?, ?, ?)',
                    [$id, $email, password_hash($password, PASSWORD_BCRYPT)],
                );
                $db->executeStatement(
                    'insert into public.profiles (user_id, shop_id, roles, display_name) values (?, ?, ?, ?)',
                    [$id, $shop, '{' . implode(',', $roles) . '}', $name],
                );
            }

            $db->executeStatement(
                "insert into public.shop_settings (shop_id, receipt_footer) values (?, 'Merci pour votre visite !'), (?, 'Thank you for your purchase!')",
                [self::SHOP, self::OTHER_SHOP],
            );

            // C1 is the counter, S1 the device that takes payment in the room.
            foreach (self::TERMINALS as [$id, $shop, $code]) {
                $db->executeStatement('insert into public.terminals (id, shop_id, code) values (?, ?, ?)', [$id, $shop, $code]);
            }

            foreach (self::TABLES as [$id, $name, $order]) {
                $db->executeStatement(
                    'insert into public.dining_tables (id, shop_id, name, sort_order) values (?, ?, ?, ?)',
                    [$id, self::SHOP, $name, $order],
                );
            }
            $db->executeStatement(
                "insert into public.dining_tables (id, shop_id, name, sort_order) values ('dddddddd-dddd-4ddd-8ddd-ddddddddddb1', ?, 'Other table', 1)",
                [self::OTHER_SHOP],
            );

            foreach (self::CATEGORIES as [$id, $name, $color]) {
                $db->executeStatement(
                    'insert into public.categories (id, shop_id, name, color) values (?, ?, ?, ?)',
                    [$id, self::SHOP, $name, $color],
                );
            }
            $db->executeStatement(
                "insert into public.categories (id, shop_id, name, color) values ('44444444-4444-4444-8444-444444444411', ?, 'General', '#6366f1')",
                [self::OTHER_SHOP],
            );

            // Bottled drinks are counted because running out of them is real; what the machine or
            // the kitchen makes to order is not, which is what track_stock is for.
            foreach (self::PRODUCTS as [$id, $category, $name, $millimes, $barcode, $counted, $stock]) {
                $db->executeStatement(
                    'insert into public.products (id, shop_id, category_id, name, price_millimes, barcode, track_stock) values (?, ?, ?, ?, ?, ?, ?)',
                    [$id, self::SHOP, $category, $name, $millimes, $barcode, $counted ? 'true' : 'false'],
                );
                $this->openingStock($db, self::SHOP, $id, $stock);
            }

            foreach (self::OTHER_PRODUCTS as [$id, $name, $millimes, $barcode, $stock]) {
                $db->executeStatement(
                    "insert into public.products (id, shop_id, category_id, name, price_millimes, barcode, track_stock) values (?, ?, '44444444-4444-4444-8444-444444444411', ?, ?, ?, true)",
                    [$id, self::OTHER_SHOP, $name, $millimes, $barcode],
                );
                $this->openingStock($db, self::OTHER_SHOP, $id, $stock);
            }
        });
    }

    /** Opening stock goes through the movement log, like every other stock change. */
    private function openingStock(Connection $db, string $shop, string $product, int $quantity): void
    {
        if ($quantity > 0) {
            $db->executeStatement(
                "select private.move_stock(?, ?, ?, 'opening', null, 'Seed data', null)",
                [$shop, $product, $quantity],
            );
        }
    }
}
