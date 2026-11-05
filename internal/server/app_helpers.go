package server

import (
	"context"
	"fmt"

	"tronbyt-server/internal/data"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// generateUniqueIname generates a unique 3-digit string for an app installation name (iname).
// It finds the maximum existing iname for the device and increments it.
func generateUniqueIname(db *gorm.DB, deviceID string) (string, error) {
	var maxIname int
	// Use COALESCE to handle case with no apps, defaulting to 99 so next is 100.
	// CAST(iname AS INTEGER) works in both SQLite and Postgres.
	err := gorm.G[data.App](db).
		Where("device_id = ?", deviceID).
		Select("COALESCE(MAX(CAST(iname AS INTEGER)), 99)").
		Scan(context.Background(), &maxIname)

	if err != nil {
		return "", fmt.Errorf("failed to get max iname: %w", err)
	}

	return fmt.Sprintf("%d", maxIname+1), nil
}

// getMaxAppOrder retrieves the current maximum order for apps on a specific device.
// It returns 0 if no apps exist or if an error (other than record not found) occurs.
func getMaxAppOrder(db *gorm.DB, deviceID string) (int, error) {
	var currentMax int
	// Use Order + Limit + Pluck which is dialect-agnostic and handles quoting
	// This approach is safer than Select("MAX(order)") or Select(clause.Expr) which caused issues.
	// If the column is indexed, performance is comparable to MAX().
	if err := db.Model(&data.App{}).
		Where("device_id = ?", deviceID).
		Order(clause.OrderByColumn{Column: clause.Column{Name: "order"}, Desc: true}).
		Limit(1).
		Pluck("order", &currentMax).Error; err != nil && err != gorm.ErrRecordNotFound {
		return 0, fmt.Errorf("failed to get max app order: %w", err)
	}

	return currentMax, nil
}

// makeRoomForApp renumbers a device's apps 0..n in their current order,
// leaving a gap at position (clamped to the end), and returns that position
// as the order for the app about to be inserted.
func makeRoomForApp(ctx context.Context, db *gorm.DB, deviceID string, position int) (int, error) {
	existing, err := gorm.G[data.App](db).
		Where("device_id = ?", deviceID).
		Order(clause.OrderByColumn{Column: clause.Column{Name: "order"}}).
		Find(ctx)
	if err != nil {
		return 0, fmt.Errorf("failed to load app order: %w", err)
	}
	position = min(position, len(existing))
	for i, app := range existing {
		want := i
		if i >= position {
			want = i + 1
		}
		if app.Order == want {
			continue
		}
		if _, err := gorm.G[data.App](db).Where("id = ?", app.ID).Update(ctx, "order", want); err != nil {
			return 0, fmt.Errorf("failed to shift app order: %w", err)
		}
	}
	return position, nil
}

// insertApp stores a new installation on a device. position >= 0 puts it at
// that index; otherwise it goes on top or at the bottom per the user's
// AddAppsToTop preference. Sets app.Order.
func (s *Server) insertApp(ctx context.Context, user *data.User, deviceID string, app *data.App, position int) error {
	return s.DB.Transaction(func(tx *gorm.DB) error {
		switch {
		case position >= 0:
			order, err := makeRoomForApp(ctx, tx, deviceID, position)
			if err != nil {
				return err
			}
			app.Order = order
		case user != nil && user.AddAppsToTop:
			if _, err := gorm.G[data.App](tx).
				Where("device_id = ?", deviceID).
				Update(ctx, "order", gorm.Expr("? + 1", clause.Column{Name: "order"})); err != nil {
				return err
			}
			app.Order = 0
		default:
			maxOrder, err := getMaxAppOrder(tx, deviceID)
			if err != nil {
				return err
			}
			app.Order = maxOrder + 1
		}
		return gorm.G[data.App](tx).Create(ctx, app)
	})
}
