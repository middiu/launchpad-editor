//
//  HNLaunchpadDataSet.m
//  Launchpad Editor
//
//  Created by David Deller on 11/10/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "HNLaunchpadDataSet.h"

#import "HNLaunchpadContainer.h"
#import "HNLaunchpadPage.h"
#import "HNLaunchpadGroup.h"
#import "HNLaunchpadApp.h"
#import "HNLaunchpadPasteboardType.h"

#import "FMDatabase.h"
#import "FMResultSet.h"

@implementation HNLaunchpadDataSet

static int const TYPE_PAGE = 3;
static int const TYPE_GROUP = 2;
static int const TYPE_APP = 4;

@synthesize itemTree;
@synthesize itemList;

#pragma mark -
#pragma mark Loading data

- (void)awakeFromNib
{
    [self load];
}

/**
 * Determines the filename of the Launchpad database.
 */
- (NSString *)dbFilename
{
    return [NSString stringWithFormat:@"%@/Desktop/launchpad.db", NSHomeDirectory()];
}

/**
 * Returns an opened database connection. Don't forget to close it when you're done.
 */
- (FMDatabase *)db
{
    NSString *filename = [self dbFilename];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filename])
    {
        [NSException raise:@"Database read error" format:@"Database at path: %@ does not exist", filename];
        return nil;
    }
    
    FMDatabase *db = [FMDatabase databaseWithPath:filename];
    
    if (![db open])
    {
        [NSException raise:@"Database open error" format:@"Could not open database: %@", filename];
        return nil;
    }
    
    return db;
}

- (void)load
{
    FMDatabase *db = [self db];
    
    MGOrderedDictionary *pages = [self loadPagesFromDb:db];
    NSDictionary *groups = [self loadGroupsFromDb:db];
    NSDictionary *apps = [self loadAppsFromDb:db];
    
    [self collateApps:apps andGroups:groups intoPages:pages fromDb:db];
    
    self.itemTree = pages;
    
    self.itemList = [NSMutableDictionary dictionaryWithCapacity:2000];
    [self.itemList addEntriesFromDictionary:pages];
    [self.itemList addEntriesFromDictionary:groups];
    [self.itemList addEntriesFromDictionary:apps];
    
    [db close];
}

- (MGOrderedDictionary *)loadPagesFromDb:(FMDatabase *)db
{
    MGOrderedDictionary *pages = [MGOrderedDictionary dictionaryWithCapacity:10];
    
    NSString *sql = @"SELECT *"
                        " FROM items i"
                            " JOIN groups g ON i.rowid = g.item_id"
                        " WHERE i.type = ?"
                        " ORDER BY i.ordering";
    
    FMResultSet *results = [db executeQuery:sql, [NSNumber numberWithInt:TYPE_PAGE]];
    
    if (results == nil)
    {
        [NSException raise:@"Database error" format:[db lastErrorMessage]];
        return nil;
    }
    
    int pageNumber = 0;
    
    while ([results next])
    {
        // FIXME: hacky
        if ([[results stringForColumn:@"uuid"] isEqualToString:@"HOLDINGPAGE"])
        {
            continue;
        }
        
        HNLaunchpadPage *page = [[HNLaunchpadPage alloc] init];
        
        pageNumber++;
        
        page.uuid = [results stringForColumn:@"uuid"];
        page.id = [NSNumber numberWithInt:[results intForColumn:@"rowid"]];
        page.pageNumber = pageNumber;
        page.items = [MGOrderedDictionary dictionaryWithCapacity:40];
        
        [pages setObject:page forKey:page.id];
    }
    
    return pages;
}

- (NSDictionary *)loadGroupsFromDb:(FMDatabase *)db
{
    NSMutableDictionary *groups = [NSMutableDictionary dictionaryWithCapacity:100];
    
    NSString *sql = @"SELECT *"
                    " FROM items i"
                        " JOIN groups g ON i.rowid = g.item_id"
                    " WHERE i.type = ?"
                    " ORDER BY i.ordering";
    
    FMResultSet *results = [db executeQuery:sql, [NSNumber numberWithInt:TYPE_GROUP]];
    
    if (results == nil)
    {
        [NSException raise:@"Database error" format:[db lastErrorMessage]];
        return nil;
    }
    
    while ([results next])
    {
        HNLaunchpadGroup *group = [[HNLaunchpadGroup alloc] init];
        
        group.uuid = [results stringForColumn:@"uuid"];
        group.id = [NSNumber numberWithInt:[results intForColumn:@"item_id"]];
        group.parentId = [NSNumber numberWithInt:[results intForColumn:@"parent_id"]];
        group.title = [results stringForColumn:@"title"];
        group.items = [MGOrderedDictionary dictionaryWithCapacity:40];
        
        [groups setObject:group forKey:group.id];
    }
    
    return [NSDictionary dictionaryWithDictionary:groups];
}

- (NSDictionary *)loadAppsFromDb:(FMDatabase *)db
{
    NSMutableDictionary *apps = [NSMutableDictionary dictionaryWithCapacity:1000];
    
    NSString *sql = @"SELECT *"
                    " FROM items i"
                        " JOIN apps a ON i.rowid = a.item_id"
                    " ORDER BY i.ordering";
    
    FMResultSet *results = [db executeQuery:sql];
    
    if (results == nil)
    {
        [NSException raise:@"Database error" format:[db lastErrorMessage]];
        return nil;
    }
    
    while ([results next])
    {
        HNLaunchpadApp *app = [[HNLaunchpadApp alloc] init];
        
        app.uuid = [results stringForColumn:@"uuid"];
        app.id = [NSNumber numberWithInt:[results intForColumn:@"item_id"]];
        app.parentId = [NSNumber numberWithInt:[results intForColumn:@"parent_id"]];
        app.title = [results stringForColumn:@"title"];
        
        [apps setObject:app forKey:app.id];
    }
    
    return [NSDictionary dictionaryWithDictionary:apps];
}

/**
 * This takes the apps and groups that have already been loaded, and puts them into the proper hierarchical order.
 * I couldn't find a way to do this during the first pass, because it might have been necessary to insert apps into parent objects that had not appeared yet based on the ordering.
 * From my observation, pages seem to appear before groups based on this ordering, but none of this behaviour is documented so I'm being extra careful.
 */
- (void)collateApps:(NSDictionary *)apps andGroups:(NSDictionary *)groups intoPages:(MGOrderedDictionary *)pages fromDb:(FMDatabase *)db
{
    NSString *sql = @"SELECT i.rowid AS item_id, i.parent_id, i.type"
                        " FROM items i"
                            " JOIN items parent ON i.parent_id = parent.rowid"
                            " LEFT JOIN groups g ON i.rowid = g.item_id"
                            " LEFT JOIN apps a ON i.rowid = a.item_id"
                        " WHERE i.type = ? OR i.type = ?"
                        " ORDER BY parent.ordering, i.ordering";
    
    FMResultSet *results = [db executeQuery:sql, [NSNumber numberWithInt:TYPE_APP], [NSNumber numberWithInt:TYPE_GROUP]];
    
    while ([results next])
    {
        if ([results intForColumn:@"type"] == TYPE_APP)
        {
            HNLaunchpadApp *app = [apps objectForKey:[NSNumber numberWithInt:[results intForColumn:@"item_id"]]];
            
            // is this app in a page?
            HNLaunchpadPage *containerPage = [pages objectForKey:[NSNumber numberWithInt:[results intForColumn:@"parent_id"]]];
            if (containerPage != nil)
            {
                [containerPage.items setObject:app forKey:app.id];
            }
            else
            {
                // is this app in a group?
                HNLaunchpadGroup *containerGroup = [groups objectForKey:[NSNumber numberWithInt:[results intForColumn:@"parent_id"]]];
                if (containerGroup != nil)
                {
                    [containerGroup.items setObject:app forKey:app.id];
                }
                else
                {
                    // exception
                    [NSException raise:@"Container not found" format:@"Could not find container object for app: %@", app];
                    continue;
                }
            }
        }
        else if ([results intForColumn:@"type"] == TYPE_GROUP)
        {
            HNLaunchpadGroup *group = [groups objectForKey:[NSNumber numberWithInt:[results intForColumn:@"item_id"]]];
            
            HNLaunchpadPage *containerPage = [pages objectForKey:[NSNumber numberWithInt:[results intForColumn:@"parent_id"]]];
            if (containerPage != nil)
            {
                [containerPage.items setObject:group forKey:group.id];
            }
            else
            {
                // exception
                [NSException raise:@"Container not found" format:@"Could not find container object for group: %@", group];
                continue;
            }
        }
        else
        {
            
        }
    }
}

#pragma mark -
#pragma mark Saving data

- (void)saveItem:(id)item
{
    if ([item isKindOfClass:[HNLaunchpadApp class]])
    {
        
    }
    else if ([item isKindOfClass:[HNLaunchpadGroup class]])
    {
        HNLaunchpadGroup *group = (HNLaunchpadGroup *)item;
        
        FMDatabase *db = [self db];
        
        NSString *sql = @"UPDATE groups"
                            " SET title = ?"
                            " WHERE item_id = ?";
        
        if (![db executeUpdate:sql, group.title, group.id])
        {
            [NSException raise:@"Database error" format:[db lastErrorMessage]];
            [db close];
            return;
        }
        
        [db close];
    }
    else
    {
        [NSException raise:@"Invalid class" format:@"Can only save objects of class HNLaunchpadApp, HNLaunchpadGroup"];
        return;
    }
}

#pragma mark -
#pragma mark NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
    if (item == nil)
    {
        return [self.itemTree count];
    }
    else if ([item isKindOfClass:[HNLaunchpadPage class]])
    {
        HNLaunchpadPage *page = (HNLaunchpadPage *)item;
        
        return [page.items count];
    }
    else if ([item isKindOfClass:[HNLaunchpadGroup class]])
    {
        HNLaunchpadGroup *group = (HNLaunchpadGroup *)item;
        
        return [group.items count];
    }
    else if ([item isKindOfClass:[HNLaunchpadApp class]])
    {
        return 0;
    }
    else
    {
        [NSException raise:@"Unknown NSOutlineViewDatasource item" format:@"Unknown kind of item"];
        return 0;
    }
}


- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    if ([self outlineView:outlineView numberOfChildrenOfItem:item] > 0)
    {
        return YES;
    }
    else
    {
        return NO;
    }
}


- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
    
    if (item == nil)
    {
        return [self.itemTree objectForKey:[self.itemTree keyAtIndex:index]];
    }
    else if ([item isKindOfClass:[HNLaunchpadPage class]])
    {
        HNLaunchpadPage *page = (HNLaunchpadPage *)item;
        
        return [page.items objectForKey:[page.items keyAtIndex:index]];
    }
    else if ([item isKindOfClass:[HNLaunchpadGroup class]])
    {
        HNLaunchpadGroup *group = (HNLaunchpadGroup *)item;
        
        return [group.items objectForKey:[group.items keyAtIndex:index]];
    }
    else
    {
        [NSException raise:@"Unknown NSOutlineViewDataSource child" format:@"Item has no children"];
        return nil;
    }
}


- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
    if ([item isKindOfClass:[HNLaunchpadPage class]])
    {
        HNLaunchpadPage *page = (HNLaunchpadPage *)item;
        
        return [NSString stringWithFormat:@"Page %i", page.pageNumber];
    }
    else if ([item isKindOfClass:[HNLaunchpadGroup class]])
    {
        HNLaunchpadGroup *group = (HNLaunchpadGroup *)item;
        
        return group.title;
    }
    else if ([item isKindOfClass:[HNLaunchpadApp class]])
    {
        HNLaunchpadApp *app = (HNLaunchpadApp *)item;
        
        return app.title;
    }
    else
    {
        [NSException raise:@"Unknown NSOutlineViewDataSource item" format:@"Unknown kind of item"];
        return @"Unknown";
    }
}

- (void)outlineView:(NSOutlineView *)outlineView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
    if ([item isKindOfClass:[HNLaunchpadGroup class]])
    {
        HNLaunchpadGroup *group = (HNLaunchpadGroup *)item;
        NSString *newTitle = (NSString *)object;
        
        group.title = newTitle;
        
        [self saveItem:group];
    }
    else
    {
        [NSException raise:@"Cannot rename object" format:@"Only HNLaunchpadGroup objects can be renamed"];
        return;
    }
}

#pragma mark -
#pragma mark Drag & drop

- (BOOL)outlineView:(NSOutlineView *)outlineView writeItems:(NSArray *)items toPasteboard:(NSPasteboard *)pboard
{
    if ([items count] > 1)
    {
        return NO;
    }
    
    [pboard declareTypes:[NSArray arrayWithObject:HNLaunchpadPasteboardType] owner:nil];
    
    id <HNLaunchpadEntity> item = [items objectAtIndex:0];
    NSString *id = [item.id stringValue];
    
    [pboard setString:id forType:HNLaunchpadPasteboardType];
    
    return YES;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView validateDrop:(id <NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index
{
    NSNumber *sourceItemId = [NSNumber numberWithInteger:[[[info draggingPasteboard] stringForType:HNLaunchpadPasteboardType] integerValue]];
    id <HNLaunchpadEntity> sourceItem = [self.itemList objectForKey:sourceItemId];
    
    NSLog(@"want to drop sourceItemId: %@, sourceItem: %@, item: %@, index: %ld", sourceItemId, sourceItem, item, index);
    
    // pages can only be reordered at the top level
    if ([sourceItem isKindOfClass:[HNLaunchpadPage class]])
    {
        // nil means top level
        if (item == nil)
        {
            return NSDragOperationEvery;
        }
        else
        {
            return NSDragOperationNone;
        }
    }
    // groups can only be reordered within pages (not within groups)
    else if ([sourceItem isKindOfClass:[HNLaunchpadGroup class]])
    {
        if ([item isKindOfClass:[HNLaunchpadPage class]])
        {
            return NSDragOperationEvery;
        }
        else
        {
            return NSDragOperationNone;
        }
    }
    // apps can be reordered within pages or groups, not within apps 
    else if ([sourceItem isKindOfClass:[HNLaunchpadApp class]])
    {
        if ([item isKindOfClass:[HNLaunchpadPage class]])
        {
            return NSDragOperationEvery;
        }
        else if ([item isKindOfClass:[HNLaunchpadGroup class]])
        {
            return NSDragOperationEvery;
        }
        else
        {
            return NSDragOperationNone;
        }
    }
    // what.
    else
    {
        return NSDragOperationNone;
    }
}

- (BOOL)outlineView:(NSOutlineView *)outlineView acceptDrop:(id <NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index
{
    NSNumber *sourceItemId = [NSNumber numberWithInteger:[[[info draggingPasteboard] stringForType:HNLaunchpadPasteboardType] integerValue]];
    id <HNLaunchpadEntity> sourceItem = [self.itemList objectForKey:sourceItemId];
    
    NSLog(@"dropped item: %@, index: %ld", item, index);
    
    if ([sourceItem isKindOfClass:[HNLaunchpadPage class]])
    {
        return NO;
    }
    else if ([sourceItem isKindOfClass:[HNLaunchpadGroup class]])
    {
        return NO;
    }
    else if ([sourceItem isKindOfClass:[HNLaunchpadApp class]])
    {
        if (![item isKindOfClass:[HNLaunchpadPage class]] && ![item isKindOfClass:[HNLaunchpadGroup class]])
        {
            return NO;
        }
        
        id <HNLaunchpadItem> child = (id)sourceItem;
        id <HNLaunchpadContainer> oldParent = [self.itemList objectForKey:child.parentId];
        id <HNLaunchpadContainer> newParent = item;
        
        if (oldParent == newParent)
        {
            
        }
        else
        {
            
        }
        
        return YES;
    }
    else
    {
        return NO;
    }
}

#pragma mark -
#pragma mark NSOutlineViewDelegate

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item
{
    if ([item isKindOfClass:[HNLaunchpadPage class]])
    {
        return NO;
    }
    else
    {
        return YES;
    }
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldEditTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    if ([item isKindOfClass:[HNLaunchpadGroup class]])
    {
        return YES;
    }
    else
    {
        return NO;
    }
}

@end
